-- | Semantics of abilities in terms of actions and the AI procedure
-- for picking the best action for an actor.
module Game.LambdaHack.Client.AI.ConditionClient
  ( condTgtEnemyPresentM
  , condTgtEnemyRememberedM
  , condAnyFoeAdjM
  , condHpTooLowM
  , condOnTriggerableM
  , condBlocksFriendsM
  , condFloorWeaponM
  , condNoEqpWeaponM
  , condCanProjectM
  , condNotCalmEnoughM
  , condDesirableFloorItemM
  , condMeleeBadM
  , condLightBetraysM
  , benAvailableItems
  , benGroundItems
  , threatDistList
  , fleeList
  ) where

import Control.Applicative
import Control.Arrow ((&&&))
import Control.Exception.Assert.Sugar
import Control.Monad
import qualified Data.EnumMap.Strict as EM
import Data.List
import Data.Maybe
import Data.Ord

import Game.LambdaHack.Client.AI.Preferences
import Game.LambdaHack.Client.CommonClient
import Game.LambdaHack.Client.MonadClient
import Game.LambdaHack.Client.State
import qualified Game.LambdaHack.Common.Ability as Ability
import Game.LambdaHack.Common.Actor
import Game.LambdaHack.Common.ActorState
import Game.LambdaHack.Common.Faction
import Game.LambdaHack.Common.Item
import Game.LambdaHack.Common.ItemStrongest
import qualified Game.LambdaHack.Common.Kind as Kind
import Game.LambdaHack.Common.Level
import Game.LambdaHack.Common.Misc
import Game.LambdaHack.Common.MonadStateRead
import Game.LambdaHack.Common.Point
import Game.LambdaHack.Common.Request
import Game.LambdaHack.Common.State
import qualified Game.LambdaHack.Common.Tile as Tile
import Game.LambdaHack.Common.Vector
import qualified Game.LambdaHack.Content.ItemKind as IK

-- | Require that the target enemy is visible by the party.
condTgtEnemyPresentM :: MonadClient m => ActorId -> m Bool
condTgtEnemyPresentM aid = do
  btarget <- getsClient $ getTarget aid
  return $! case btarget of
    Just (TEnemy _ permit) -> not permit
    _ -> False

-- | Require that the target enemy is remembered on the actor's level.
condTgtEnemyRememberedM :: MonadClient m => ActorId -> m Bool
condTgtEnemyRememberedM aid = do
  b <- getsState $ getActorBody aid
  btarget <- getsClient $ getTarget aid
  return $! case btarget of
    Just (TEnemyPos _ lid _ permit) | lid == blid b -> not permit
    _ -> False

-- | Require that any non-dying foe is adjacent.
condAnyFoeAdjM :: MonadStateRead m => ActorId -> m Bool
condAnyFoeAdjM aid = do
  b <- getsState $ getActorBody aid
  fact <- getsState $ (EM.! bfid b) . sfactionD
  allFoes <- getsState $ actorRegularList (isAtWar fact) (blid b)
  return $ any (adjacent (bpos b) . bpos) allFoes  -- keep it lazy

-- | Require the actor's HP is low enough.
condHpTooLowM :: MonadClient m => ActorId -> m Bool
condHpTooLowM aid = do
  b <- getsState $ getActorBody aid
  activeItems <- activeItemsClient aid
  return $! hpTooLow b activeItems

-- | Require the actor stands over a triggerable tile.
condOnTriggerableM :: MonadStateRead m => ActorId -> m Bool
condOnTriggerableM aid = do
  Kind.COps{cotile} <- getsState scops
  b <- getsState $ getActorBody aid
  lvl <- getLevel $ blid b
  let t = lvl `at` bpos b
  return $! not $ null $ Tile.causeEffects cotile t

-- | Produce the chess-distance-sorted list of non-low-HP foes on the level.
-- We don't consider path-distance, because we are interested in how soon
-- the foe can hit us, which can diverge greately from path distance
-- for short distances.
threatDistList :: MonadClient m => ActorId -> m [(Int, (ActorId, Actor))]
threatDistList aid = do
  b <- getsState $ getActorBody aid
  fact <- getsState $ (EM.! bfid b) . sfactionD
  allAtWar <- getsState $ actorRegularAssocs (isAtWar fact) (blid b)
  let strongActor (aid2, b2) = do
        activeItems <- activeItemsClient aid2
        return $! not $ hpTooLow b2 activeItems
  allThreats <- filterM strongActor allAtWar
  let addDist (aid2, b2) = (chessDist (bpos b) (bpos b2), (aid2, b2))
  return $ sortBy (comparing fst) $ map addDist allThreats

-- | Require the actor blocks the paths of any of his party members.
condBlocksFriendsM :: MonadClient m => ActorId -> m Bool
condBlocksFriendsM aid = do
  b <- getsState $ getActorBody aid
  ours <- getsState $ actorRegularAssocs (== bfid b) (blid b)
  targetD <- getsClient stargetD
  let blocked (aid2, _) = aid2 /= aid &&
        case EM.lookup aid2 targetD of
          Just (_, Just (_ : q : _, _)) | q == bpos b -> True
          _ -> False
  return $ any blocked ours  -- keep it lazy

-- | Require the actor stands over a weapon that would be auto-equipped.
condFloorWeaponM :: MonadClient m => ActorId -> m Bool
condFloorWeaponM aid = do
  floorAssocs <- fullAssocsClient aid [CGround]
  let lootIsWeapon = any (isMeleeEqp . snd) floorAssocs
  return $ lootIsWeapon  -- keep it lazy

-- | Check whether the actor has no weapon in equipment.
condNoEqpWeaponM :: MonadClient m => ActorId -> m Bool
condNoEqpWeaponM aid = do
  allAssocs <- fullAssocsClient aid [CEqp]
  return $ all (not . isMelee . snd) allAssocs  -- keep it lazy

-- | Require that the actor can project any items.
condCanProjectM :: MonadClient m => ActorId -> m Bool
condCanProjectM aid = do
  actorSk <- actorSkillsClient aid
  let skill = EM.findWithDefault 0 Ability.AbProject actorSk
      q _ itemFull b activeItems =
        either (const False) id
        $ permittedProject " " False skill itemFull b activeItems
  benList <- benAvailableItems aid q [CEqp, CInv, CGround]
  let missiles = filter (maybe True ((< 0) . snd) . fst . fst) benList
  return $ not (null missiles)
    -- keep it lazy

-- | Produce the list of items with a given property available to the actor
-- and the items' values.
benAvailableItems :: MonadClient m
                  => ActorId
                  -> (Maybe Int -> ItemFull -> Actor -> [ItemFull] -> Bool)
                  -> [CStore]
                  -> m [( (Maybe (Int, Int), (Int, CStore))
                        , (ItemId, ItemFull) )]
benAvailableItems aid permitted cstores = do
  cops <- getsState scops
  itemToF <- itemToFullClient
  b <- getsState $ getActorBody aid
  activeItems <- activeItemsClient aid
  fact <- getsState $ (EM.! bfid b) . sfactionD
  let ben cstore bag =
        [ ((benefit, (k, cstore)), (iid, itemFull))
        | (iid, kit@(k, _)) <- EM.assocs bag
        , let itemFull = itemToF iid kit
        , let benefit = totalUsefulness cops b activeItems fact itemFull
        , permitted (fst <$> benefit) itemFull b activeItems ]
      benCStore cs = do
        bag <- getsState $ getActorBag aid cs
        return $! ben cs bag
  perBag <- mapM benCStore cstores
  return $ concat perBag
    -- keep it lazy

-- | Require the actor is not calm enough.
condNotCalmEnoughM :: MonadClient m => ActorId -> m Bool
condNotCalmEnoughM aid = do
  b <- getsState $ getActorBody aid
  activeItems <- activeItemsClient aid
  return $! not (calmEnough b activeItems)

-- | Require that the actor stands over a desirable item.
condDesirableFloorItemM :: MonadClient m => ActorId -> m Bool
condDesirableFloorItemM aid = do
  benItemL <- benGroundItems aid
  return $ not $ null benItemL  -- keep it lazy

-- | Produce the list of items on the ground beneath the actor
-- that are worth picking up.
benGroundItems :: MonadClient m
               => ActorId
               -> m [( (Maybe (Int, Int)
                     , (Int, CStore)), (ItemId, ItemFull) )]
benGroundItems aid = do
  b <- getsState $ getActorBody aid
  canEscape <- factionCanEscape (bfid b)
  let -- A hack to prevent monsters from picking up treasure.
      preciousWithoutSlot item =
        IK.Precious `elem` jfeature item  -- risk from treasure hunters
        && isNothing (strengthEqpSlot item)  -- unlikely to be useful
      desirableItem use ItemFull{itemBase} _ _
        | canEscape = use /= Just 0
                      || IK.Precious `elem` jfeature itemBase
        | otherwise = use /= Just 0
                      && not (isNothing use  -- needs resources to id
                              && preciousWithoutSlot itemBase)
  benAvailableItems aid desirableItem [CGround]

-- | Require the actor is in a bad position to melee or can't melee at all.
condMeleeBadM :: MonadClient m => ActorId -> m Bool
condMeleeBadM aid = do
  b <- getsState $ getActorBody aid
  fact <- getsState $ (EM.! bfid b) . sfactionD
  allAssocs <- fullAssocsClient aid [COrgan, CEqp]
  let condNoUsableWeapon = all (not . isMelee . snd) allAssocs
      friendlyFid fid = fid == bfid b || isAllied fact fid
  friends <- getsState $ actorRegularAssocs friendlyFid (blid b)
  let closeEnough b2 = let dist = chessDist (bpos b) (bpos b2)
                       in dist < 3 && dist > 0
      closeFriends = filter (closeEnough . snd) friends
      strongActor (aid2, b2) = do
        activeItems <- activeItemsClient aid2
        return $! not $ hpTooLow b2 activeItems
  strongCloseFriends <- filterM strongActor closeFriends
  let noFriendlyHelp = length closeFriends < 3
                       && null strongCloseFriends
                       && not (hpHuge b)  -- uniques, etc., should be aggresive
  return $ condNoUsableWeapon
           || noFriendlyHelp  -- still not getting friends' help
    -- no $!; keep it lazy

-- | Require that the actor stands in the dark, but is betrayed
-- by his own equipped light,
condLightBetraysM :: MonadClient m => ActorId -> m Bool
condLightBetraysM aid = do
  b <- getsState $ getActorBody aid
  eqpItems <- map snd <$> fullAssocsClient aid [CEqp]
  let actorEqpShines = sumSlotNoFilter IK.EqpSlotAddLight eqpItems > 0
  aInAmbient<- getsState $ actorInAmbient b
  return $! not aInAmbient     -- tile is dark, so actor could hide
            && actorEqpShines  -- but actor betrayed by his equipped light

-- | Produce a list of acceptable adjacent points to flee to.
fleeList :: MonadClient m => Bool -> ActorId -> m [(Int, Point)]
fleeList panic aid = do
  cops <- getsState scops
  mtgtMPath <- getsClient $ EM.lookup aid . stargetD
  let tgtPath = case mtgtMPath of  -- prefer fleeing along the path to target
        Just (_, Just (_ : path, _)) -> path
        _ -> []
  b <- getsState $ getActorBody aid
  fact <- getsState $ \s -> sfactionD s EM.! bfid b
  allFoes <- getsState $ actorRegularList (isAtWar fact) (blid b)
  lvl@Level{lxsize, lysize} <- getLevel $ blid b
  let posFoes = map bpos allFoes
      accessibleHere = accessible cops lvl $ bpos b
      myVic = vicinity lxsize lysize $ bpos b
      dist p | null posFoes = assert `failure` b
             | otherwise = minimum $ map (chessDist p) posFoes
      dVic = map (dist &&& id) myVic
      -- Flee, if possible. Access required.
      accVic = filter (accessibleHere . snd) $ dVic
      gtVic = filter ((> dist (bpos b)) . fst) accVic
      -- At least don't get closer to enemies, but don't stay adjacent.
      eqVic = filter (\(d, _) -> d == dist (bpos b) && d > 1) accVic
      rewardPath (d, p) =
        if p `elem` tgtPath then Just (9 * d, p)
        else if any (\q -> chessDist p q == 1) tgtPath then Just (d, p)
        else Nothing
      goodVic = mapMaybe rewardPath gtVic
                ++ filter ((`elem` tgtPath) . snd) eqVic
      pathVic = goodVic ++ if panic then accVic \\ goodVic else []
  return pathVic  -- keep it lazy, until other conditions verify danger
