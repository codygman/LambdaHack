-- | Operations for starting and restarting the game.
module Game.LambdaHack.Server.StartServer
  ( gameReset, reinitGame, initPer, recruitActors, applyDebug, initDebug
  ) where

import Control.Applicative
import Control.Exception.Assert.Sugar
import Control.Monad
import qualified Control.Monad.State as St
import qualified Data.Char as Char
import qualified Data.EnumMap.Strict as EM
import qualified Data.EnumSet as ES
import Data.List
import qualified Data.Map.Strict as M
import Data.Maybe
import Data.Ord
import Data.Text (Text)
import qualified Data.Text as T
import Data.Tuple (swap)
import qualified System.Random as R

import Game.LambdaHack.Atomic
import Game.LambdaHack.Common.Actor
import Game.LambdaHack.Common.ActorState
import Game.LambdaHack.Common.ClientOptions
import qualified Game.LambdaHack.Common.Color as Color
import Game.LambdaHack.Common.Faction
import Game.LambdaHack.Common.Flavour
import qualified Game.LambdaHack.Common.HighScore as HighScore
import Game.LambdaHack.Common.Item
import qualified Game.LambdaHack.Common.Kind as Kind
import Game.LambdaHack.Common.Level
import Game.LambdaHack.Common.Misc
import Game.LambdaHack.Common.MonadStateRead
import Game.LambdaHack.Common.Msg
import Game.LambdaHack.Common.Point
import Game.LambdaHack.Common.Random
import Game.LambdaHack.Common.State
import qualified Game.LambdaHack.Common.Tile as Tile
import Game.LambdaHack.Common.Time
import Game.LambdaHack.Content.ItemKind (ItemKind)
import qualified Game.LambdaHack.Content.ItemKind as IK
import Game.LambdaHack.Content.ModeKind
import Game.LambdaHack.Content.RuleKind
import qualified Game.LambdaHack.Content.TileKind as TK
import Game.LambdaHack.Server.CommonServer
import qualified Game.LambdaHack.Server.DungeonGen as DungeonGen
import Game.LambdaHack.Server.Fov
import Game.LambdaHack.Server.ItemRev
import Game.LambdaHack.Server.ItemServer
import Game.LambdaHack.Server.MonadServer
import Game.LambdaHack.Server.State

initPer :: MonadServer m => m ()
initPer = do
  fovMode <- getsServer $ sfovMode . sdebugSer
  ser <- getServer
  pers <- getsState $ \s -> dungeonPerception (fromMaybe Digital fovMode) s ser
  modifyServer $ \ser1 -> ser1 {sper = pers}

reinitGame :: (MonadAtomic m, MonadServer m) => m ()
reinitGame = do
  Kind.COps{coitem=Kind.Ops{okind}} <- getsState scops
  pers <- getsServer sper
  DebugModeSer{scurDiff, sknowMap, sdebugCli} <- getsServer sdebugSer
  -- This state is quite small, fit for transmition to the client.
  -- The biggest part is content, which needs to be updated
  -- at this point to keep clients in sync with server improvements.
  s <- getState
  let defLocal | sknowMap = s
               | otherwise = localFromGlobal s
  discoS <- getsServer sdiscoKind
  let sdiscoKind = let f ik = IK.Identified `elem` IK.ifeature (okind ik)
               in EM.filter f discoS
  broadcastUpdAtomic
    $ \fid -> UpdRestart fid sdiscoKind (pers EM.! fid) defLocal scurDiff sdebugCli
  populateDungeon

mapFromFuns :: (Bounded a, Enum a, Ord b) => [a -> b] -> M.Map b a
mapFromFuns =
  let fromFun f m1 =
        let invAssocs = map (\c -> (f c, c)) [minBound..maxBound]
            m2 = M.fromList invAssocs
        in m2 `M.union` m1
  in foldr fromFun M.empty

lowercase :: Text -> Text
lowercase = T.pack . map Char.toLower . T.unpack

createFactions :: AbsDepth -> Roster -> Rnd FactionDict
createFactions totalDepth players = do
  let rawCreate Player{..} = do
        entryLevel <- castDice (AbsDepth 0) (AbsDepth 0) fentryLevel
        initialActors <- castDice (AbsDepth $ abs entryLevel) totalDepth
                                  finitialActors
        let gplayer = Player{ fentryLevel = entryLevel
                            , finitialActors = initialActors
                            , ..}
            cmap = mapFromFuns
                     [colorToTeamName, colorToPlainName, colorToFancyName]
            nameoc = lowercase $ head $ T.words fname
            prefix = case fleaderMode of
              LeaderNull -> "Loose"
              LeaderAI _ -> "Autonomous"
              LeaderUI _ -> "Controlled"
            (gcolor, gname) = case M.lookup nameoc cmap of
              Nothing -> (Color.BrWhite, prefix <+> fname)
              Just c -> (c, prefix <+> fname <+> "Team")
        let gdipl = EM.empty  -- fixed below
            gquit = Nothing
            gleader = Nothing
            gvictims = EM.empty
            gsha = EM.empty
        return $! Faction{..}
  lUI <- mapM rawCreate $ filter fhasUI $ rosterList players
  lnoUI <- mapM rawCreate $ filter (not . fhasUI) $ rosterList players
  let lFs = reverse (zip [toEnum (-1), toEnum (-2)..] lnoUI)  -- sorted
            ++ zip [toEnum 1..] lUI
      swapIx l =
        let findPlayerName name = find ((name ==) . fname . gplayer . snd)
            f (name1, name2) =
              case (findPlayerName name1 lFs, findPlayerName name2 lFs) of
                (Just (ix1, _), Just (ix2, _)) -> (ix1, ix2)
                _ -> assert `failure` "unknown faction"
                            `twith` ((name1, name2), lFs)
            ixs = map f l
        -- Only symmetry is ensured, everything else is permitted, e.g.,
        -- a faction in alliance with two others that are at war.
        in ixs ++ map swap ixs
      mkDipl diplMode =
        let f (ix1, ix2) =
              let adj fact = fact {gdipl = EM.insert ix2 diplMode (gdipl fact)}
              in EM.adjust adj ix1
        in foldr f
      rawFs = EM.fromDistinctAscList lFs
      -- War overrides alliance, so 'warFs' second.
      allianceFs = mkDipl Alliance rawFs (swapIx (rosterAlly players))
      warFs = mkDipl War allianceFs (swapIx (rosterEnemy players))
  return $! warFs

gameReset :: MonadServer m
          => Kind.COps -> DebugModeSer -> Maybe (GroupName ModeKind)
          -> Maybe R.StdGen -> m State
gameReset cops@Kind.COps{comode=Kind.Ops{opick, okind}}
          sdebug mGameMode mrandom = do
  dungeonSeed <- getSetGen $ sdungeonRng sdebug `mplus` mrandom
  srandom <- getSetGen $ smainRng sdebug `mplus` mrandom
  scoreTable <- if sfrontendNull $ sdebugCli sdebug then
                  return HighScore.empty
                else
                  restoreScore cops
  sstart <- getsServer sstart  -- copy over from previous game
  sallTime <- getsServer sallTime  -- copy over from previous game
  sheroNames <- getsServer sheroNames  -- copy over from previous game
  let gameMode = fromMaybe "starting" $ mGameMode `mplus` sgameMode sdebug
      rnd :: Rnd (FactionDict, FlavourMap, DiscoveryKind, DiscoveryKindRev,
                  DungeonGen.FreshDungeon, Kind.Id ModeKind)
      rnd = do
        modeKindId <- fromMaybe (assert `failure` gameMode)
                      <$> opick gameMode (const True)
        let mode = okind modeKindId
            automatePS ps = ps {rosterList =
                                  map (automatePlayer True) $ rosterList ps}
            players = if sautomateAll sdebug
                      then automatePS $ mroster mode
                      else mroster mode
        sflavour <- dungeonFlavourMap cops
        (sdiscoKind, sdiscoKindRev) <- serverDiscos cops
        freshDng <- DungeonGen.dungeonGen cops $ mcaves mode
        faction <- createFactions (DungeonGen.freshTotalDepth freshDng) players
        return (faction, sflavour, sdiscoKind, sdiscoKindRev, freshDng, modeKindId)
  let (faction, sflavour, sdiscoKind, sdiscoKindRev, DungeonGen.FreshDungeon{..}, modeKindId) =
        St.evalState rnd dungeonSeed
      defState = defStateGlobal freshDungeon freshTotalDepth
                                faction cops scoreTable modeKindId
      defSer = emptyStateServer { sstart, sallTime, sheroNames, srandom
                                , srngs = RNGs (Just dungeonSeed)
                                               (Just srandom) }
  putServer defSer
  when (sbenchmark $ sdebugCli sdebug) resetGameStart
  modifyServer $ \ser -> ser {sdiscoKind, sdiscoKindRev, sflavour}
  when (sdumpInitRngs sdebug) dumpRngs
  return $! defState

-- Spawn initial actors. Clients should notice this, to set their leaders.
populateDungeon :: (MonadAtomic m, MonadServer m) => m ()
populateDungeon = do
  cops@Kind.COps{cotile} <- getsState scops
  placeItemsInDungeon
  embedItemsInDungeon
  dungeon <- getsState sdungeon
  factionD <- getsState sfactionD
  sheroNames <- getsServer sheroNames
  let (minD, maxD) =
        case (EM.minViewWithKey dungeon, EM.maxViewWithKey dungeon) of
          (Just ((s, _), _), Just ((e, _), _)) -> (s, e)
          _ -> assert `failure` "empty dungeon" `twith` dungeon
      -- Players that escape go first to be started over stairs, if possible.
      valuePlayer pl = (not $ fcanEscape pl, fname pl)
      -- Sorting, to keep games from similar game modes mutually reproducible.
      needInitialCrew = sortBy (comparing $ valuePlayer . gplayer . snd)
                        $ filter ((> 0 ) . finitialActors . gplayer . snd)
                        $ EM.assocs factionD
      getEntryLevel (_, fact) =
        max minD $ min maxD $ toEnum $ fentryLevel $ gplayer fact
      arenas = ES.toList $ ES.fromList $ map getEntryLevel needInitialCrew
      initialActors lid = do
        lvl <- getLevel lid
        let arenaFactions = filter ((== lid) . getEntryLevel) needInitialCrew
            indexff (fid, _) = findIndex ((== fid) . fst) arenaFactions
            representsAlliance ff2@(_, fact2) =
              not $ any (\ff3@(fid3, _) ->
                           indexff ff3 < indexff ff2
                           && isAllied fact2 fid3) arenaFactions
            arenaAlliances = filter representsAlliance arenaFactions
            placeAlliance ((fid3, _), ppos, timeOffset) =
              mapM_ (\(fid4, fact4) ->
                      when (isAllied fact4 fid3 || fid4 == fid3) $
                        placeActors lid ((fid4, fact4), ppos, timeOffset))
                    arenaFactions
        entryPoss <- rndToAction
                     $ findEntryPoss cops lid lvl (length arenaAlliances)
        mapM_ placeAlliance $ zip3 arenaAlliances entryPoss [0..]
      placeActors lid ((fid3, fact3), ppos, timeOffset) = do
        time <- getsState $ getLocalTime lid
        let nmult = 1 + timeOffset `mod` 4
            ntime = timeShift time (timeDeltaScale (Delta timeClip) nmult)
            validTile t = not $ Tile.hasFeature cotile TK.NoActor t
        psFree <- getsState $ nearbyFreePoints validTile ppos lid
        let ps = take (finitialActors $ gplayer fact3) $ zip [0..] psFree
        forM_ ps $ \ (n, p) -> do
          go <-
            if not $ fhasNumbers $ gplayer fact3
            then recruitActors [p] lid ntime fid3
            else do
              let hNames = EM.findWithDefault [] fid3 sheroNames
              maid <- addHero fid3 p lid hNames (Just n) ntime
              case maid of
                Nothing -> return False
                Just aid -> do
                  mleader <- getsState $ gleader . (EM.! fid3) . sfactionD
                  when (isNothing mleader) $
                    execUpdAtomic
                    $ UpdLeadFaction fid3 Nothing (Just (aid, Nothing))
                  return True
          unless go $ assert `failure` "can't spawn initial actors"
                             `twith` (lid, (fid3, fact3))
  mapM_ initialActors arenas

-- | Spawn actors of any specified faction, friendly or not.
-- To be used for initial dungeon population and for the summon effect.
recruitActors :: (MonadAtomic m, MonadServer m)
              => [Point] -> LevelId -> Time -> FactionId
              -> m Bool
recruitActors ps lid time fid = assert (not $ null ps) $ do
  fact <- getsState $ (EM.! fid) . sfactionD
  let spawnName = fgroup $ gplayer fact
  laid <- forM ps $ \ p ->
    if fhasNumbers $ gplayer fact
    then addHero fid p lid [] Nothing time
    else addMonster spawnName fid p lid time
  case catMaybes laid of
    [] -> return False
    aid : _ -> do
      mleader <- getsState $ gleader . (EM.! fid) . sfactionD  -- just changed
      when (isNothing mleader) $
        execUpdAtomic $ UpdLeadFaction fid Nothing (Just (aid, Nothing))
      return True

-- | Create a new monster on the level, at a given position
-- and with a given actor kind and HP.
addMonster :: (MonadAtomic m, MonadServer m)
           => GroupName ItemKind -> FactionId -> Point -> LevelId -> Time
           -> m (Maybe ActorId)
addMonster groupName bfid ppos lid time = do
  fact <- getsState $ (EM.! bfid) . sfactionD
  pronoun <- if fhasGender $ gplayer fact
             then rndToAction $ oneOf ["he", "she"]
             else return "it"
  addActor groupName bfid ppos lid id pronoun time

-- | Create a new hero on the current level, close to the given position.
addHero :: (MonadAtomic m, MonadServer m)
        => FactionId -> Point -> LevelId -> [(Int, (Text, Text))]
        -> Maybe Int -> Time
        -> m (Maybe ActorId)
addHero bfid ppos lid heroNames mNumber time = do
  Faction{gcolor, gplayer} <- getsState $ (EM.! bfid) . sfactionD
  let groupName = fgroup gplayer
  mhs <- mapM (getsState . tryFindHeroK bfid) [0..9]
  let freeHeroK = elemIndex Nothing mhs
      n = fromMaybe (fromMaybe 100 freeHeroK) mNumber
      bsymbol = if n < 1 || n > 9 then '@' else Char.intToDigit n
      nameFromNumber 0 = ("Captain", "he")
      nameFromNumber k | k `mod` 7 == 0 = ("Heroine" <+> tshow k, "she")
      nameFromNumber k = ("Hero" <+> tshow k, "he")
      (bname, pronoun) | gcolor == Color.BrWhite =
        fromMaybe (nameFromNumber n) $ lookup n heroNames
                       | otherwise =
        let (nameN, pronounN) = nameFromNumber n
        in (fname gplayer <+> nameN, pronounN)
      tweakBody b = b {bsymbol, bname, bcolor = gcolor}
  addActor groupName bfid ppos lid tweakBody pronoun time

-- | Find starting postions for all factions. Try to make them distant
-- from each other. Place as many of the initial factions, as possible,
-- over stairs and escapes.
findEntryPoss :: Kind.COps -> LevelId -> Level -> Int -> Rnd [Point]
findEntryPoss Kind.COps{cotile}
              lid Level{ltile, lxsize, lysize, lstair, lescape} k = do
  let factionDist = max lxsize lysize - 5
      dist poss cmin l _ = all (\pos -> chessDist l pos > cmin) poss
      tryFind _ 0 = return []
      tryFind ps n = do
        np <- findPosTry 1000 ltile  -- try really hard, for skirmish fairness
                (\_ t -> Tile.isWalkable cotile t
                         && not (Tile.hasFeature cotile TK.NoActor t))
                [ dist ps $ factionDist `div` 2
                , dist ps $ factionDist `div` 3
                , const (Tile.hasFeature cotile TK.OftenActor)
                , dist ps $ factionDist `div` 3
                , dist ps $ factionDist `div` 4
                , dist ps $ factionDist `div` 5
                , dist ps $ factionDist `div` 7
                , dist ps $ factionDist `div` 10
                ]
        nps <- tryFind (np : ps) (n - 1)
        return $! np : nps
      -- Prefer deeper stairs to avoid spawners ambushing explorers.
      (deeperStairs, shallowerStairs) =
        (if fromEnum lid > 0 then id else swap) lstair
      stairPoss = (deeperStairs \\ shallowerStairs)
                  ++ lescape
                  ++ shallowerStairs
      middlePos = Point (lxsize `div` 2) (lysize `div` 2)
  let !_A = assert (k > 0 && factionDist > 0) ()
      onStairs = take k stairPoss
      nk = k - length onStairs
  found <- case nk of
    0 -> return []
    1 -> tryFind onStairs nk
    2 -> -- Make sure the first faction's pos is not chosen in the middle.
         tryFind (if null onStairs then [middlePos] else onStairs) nk
    _ -> tryFind onStairs nk
  return $! onStairs ++ found

initDebug :: MonadStateRead m => Kind.COps -> DebugModeSer -> m DebugModeSer
initDebug Kind.COps{corule} sdebugSer = do
  let stdRuleset = Kind.stdRuleset corule
  return $!
    (\dbg -> dbg {sfovMode =
        sfovMode dbg `mplus` Just (rfovMode stdRuleset)}) .
    (\dbg -> dbg {ssavePrefixSer =
        ssavePrefixSer dbg `mplus` Just (rsavePrefix stdRuleset)})
    $ sdebugSer

-- | Apply debug options that don't need a new game.
applyDebug :: MonadServer m => m ()
applyDebug = do
  DebugModeSer{..} <- getsServer sdebugNxt
  modifyServer $ \ser ->
    ser {sdebugSer = (sdebugSer ser) { sniffIn
                                     , sniffOut
                                     , sallClear
                                     , sfovMode
                                     , sstopAfter
                                     , sdbgMsgSer
                                     , snewGameSer
                                     , sdumpInitRngs
                                     , sdebugCli }}
