{-# LANGUAGE GeneralizedNewtypeDeriving, RankNTypes, TypeFamilies #-}
-- | General content types and operations.
module Game.LambdaHack.Common.Kind
  ( Id, Speedup, Ops(..), COps(..), createOps, stdRuleset
  ) where

import Control.Exception.Assert.Sugar
import Data.Binary
import qualified Data.EnumMap.Strict as EM
import qualified Data.Ix as Ix
import Data.List
import qualified Data.Map.Strict as M
import qualified Data.Text as T

import Game.LambdaHack.Common.ContentDef
import Game.LambdaHack.Common.Frequency
import Game.LambdaHack.Common.Misc
import Game.LambdaHack.Common.Msg
import Game.LambdaHack.Common.Random
import Game.LambdaHack.Content.CaveKind
import Game.LambdaHack.Content.ItemKind
import Game.LambdaHack.Content.ModeKind
import Game.LambdaHack.Content.PlaceKind
import Game.LambdaHack.Content.RuleKind
import Game.LambdaHack.Content.TileKind

-- | Content identifiers for the content type @c@.
newtype Id c = Id Word8
  deriving (Show, Eq, Ord, Ix.Ix, Enum, Bounded, Binary)

-- | Type family for auxiliary data structures for speeding up
-- content operations.
type family Speedup a

-- | Content operations for the content of type @a@.
data Ops a = Ops
  { okind         :: Id a -> a          -- ^ the content element at given id
  , ouniqGroup    :: GroupName a -> Id a  -- ^ the id of the unique member of
                                          --   a singleton content group
  , opick         :: GroupName a -> (a -> Bool) -> Rnd (Maybe (Id a))
                                    -- ^ pick a random id belonging to a group
                                    --   and satisfying a predicate
  , ofoldrWithKey :: forall b. (Id a -> a -> b -> b) -> b -> b
                                    -- ^ fold over all content elements of @a@
  , ofoldrGroup   :: forall b.
                     GroupName a -> (Int -> Id a -> a -> b -> b) -> b -> b
                                    -- ^ fold over the given group only
  , obounds       :: !(Id a, Id a)  -- ^ bounds of identifiers of content @a@
  , ospeedup      :: !(Maybe (Speedup a))  -- ^ auxiliary speedup components
  }

-- | Create content operations for type @a@ from definition of content
-- of type @a@.
createOps :: forall a. Show a => ContentDef a -> Ops a
createOps ContentDef{getName, getFreq, content, validateSingle, validateAll} =
  assert (length content <= fromEnum (maxBound :: Id a)) $
  let kindMap :: EM.EnumMap (Id a) a
      !kindMap = EM.fromDistinctAscList $ zip [Id 0..] content
      kindFreq :: M.Map (GroupName a) [(Int, (Id a, a))]
      kindFreq =
        let tuples = [ (cgroup, (n, (i, k)))
                     | (i, k) <- EM.assocs kindMap
                     , (cgroup, n) <- getFreq k
                     , n > 0 ]
            f m (cgroup, nik) = M.insertWith (++) cgroup [nik] m
        in foldl' f M.empty tuples
      okind i = let assFail = assert `failure` "no kind" `twith` (i, kindMap)
                in EM.findWithDefault assFail i kindMap
      correct a = not (T.null (getName a)) && all ((> 0) . snd) (getFreq a)
      singleOffenders = [ (offences, a)
                        | a <- content
                        , let offences = validateSingle a
                        , not (null offences) ]
      allOffences = validateAll content
  in assert (allB correct content) $
     assert (null singleOffenders `blame` "some content items not valid"
                                  `twith` singleOffenders) $
     assert (null allOffences `blame` "the content set not valid"
                              `twith` (allOffences, content))
     -- By this point 'content' can be GCd.
     Ops
       { okind
       , ouniqGroup = \cgroup ->
           let freq = let assFail = assert `failure` "no unique group"
                                           `twith` (cgroup, kindFreq)
                      in M.findWithDefault assFail cgroup kindFreq
           in case freq of
             [(n, (i, _))] | n > 0 -> i
             l -> assert `failure` "not unique" `twith` (l, cgroup, kindFreq)
       , opick = \cgroup p ->
           case M.lookup cgroup kindFreq of
             Just freqRaw ->
               let freq = toFreq ("opick ('" <> tshow cgroup <> "')") freqRaw
               in if nullFreq freq
                  then return Nothing
                  else fmap Just $ frequency $ do
                    (i, k) <- freq
                    breturn (p k) i
                    {- with MonadComprehensions:
                    frequency [ i | (i, k) <- kindFreq M.! cgroup, p k ]
                    -}
             _ -> return Nothing
       , ofoldrWithKey = \f z -> foldr (uncurry f) z $ EM.assocs kindMap
       , ofoldrGroup = \cgroup f z ->
           case M.lookup cgroup kindFreq of
             Just freq -> foldr (\(p, (i, a)) -> f p i a) z freq
             _ -> assert `failure` "no group '" <> tshow cgroup
                                   <> "' among content that has groups"
                                   <+> tshow (M.keys kindFreq)
       , obounds = ( fst $ EM.findMin kindMap
                   , fst $ EM.findMax kindMap )
       , ospeedup = Nothing  -- define elsewhere
       }

-- | Operations for all content types, gathered together.
data COps = COps
  { cocave  :: !(Ops CaveKind)     -- server only
  , coitem  :: !(Ops ItemKind)
  , comode  :: !(Ops ModeKind)     -- server only
  , coplace :: !(Ops PlaceKind)    -- server only, so far
  , corule  :: !(Ops RuleKind)
  , cotile  :: !(Ops TileKind)
  }

-- | The standard ruleset used for level operations.
stdRuleset :: Ops RuleKind -> RuleKind
stdRuleset Ops{ouniqGroup, okind} = okind $ ouniqGroup "standard"

instance Show COps where
  show _ = "game content"

instance Eq COps where
  (==) _ _ = True
