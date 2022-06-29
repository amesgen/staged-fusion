
{-# language
  TemplateHaskell, TypeFamilies, BlockArguments,
  MagicHash, RankNTypes, UnboxedTuples, GADTs #-}

module Pull2 where

import Data.Flat
import IO
import qualified Data.Array.FI as AFI
import qualified Data.Array.FM as AFM
import qualified Data.Array.LI as ALI
import qualified Data.Array.LM as ALM
import Data.Array.UndefElem

import Up(Up)
import qualified Up as U
import Gen

import GHC.Exts
import GHC.Int


type Step a s = forall r. Up r -> (Up a -> Up s -> Up r) -> Up r
data Pull' a = forall s. Pull' {len :: Maybe (Up Int), seed :: Up s, step :: Up s -> Step a s}
type Pull a = Gen (Pull' a)

drop# :: forall s a. Up Int -> (Up s -> Step a s) -> Up s -> Gen (Up s)
drop# n step s = Gen \ret -> [||
  let go n s | n <= (0::Int) = seq s $$(ret [||s||])
             | otherwise     = $$(step [||s||] (ret [||s||]) (\_ s -> [||go (n - 1) $$s||]))
  in go $$n $$s ||]

drop :: Up Int -> Pull a -> Pull a
drop n pa = do
  Pull' len seed step <- pa
  seed <- drop# n step seed
  pure $ Pull' (U.max 0 <$> ((-) <$> len <*> Just n)) seed step

map :: (Up a -> Up b) -> Pull a -> Pull b
map f pa = do
  Pull' len seed step <- pa
  pure $ Pull' len seed \s stop yield -> step s stop \a s -> yield (f a) s

range :: Up Int -> Up Int -> Pull Int
range lo hi = pure $
  Pull' (Just (U.max 0 (hi - lo))) (U.pair lo hi) \s stop yield ->
    U.bindPair s \curr hi ->
      U.bool (curr U.>= hi)
             stop
             (yield curr (U.pair (curr U.+ 1) hi))

countFrom :: Up Int -> Pull Int
countFrom i = pure $ Pull' Nothing i \s stop yield -> yield s (s + 1)

zipWith :: (Up a -> Up b -> Up c) -> Pull a -> Pull b -> Pull c
zipWith f pa pb = do
  Pull' len seed step    <- pa
  Pull' len' seed' step' <- pb
  pure $ Pull'
    (U.min <$> len <*> len')
    (U.pair seed seed')
    (\abs stop yield -> U.bindPair abs \as bs ->
       step as stop \a as ->
        step' bs stop \b bs ->
          yield (f a b) (U.pair as bs))

find# :: (Up a -> Up Bool) -> (Up s -> Step a s) -> Up s -> Step a s
find# f step s stop yield = [||
   let go s = $$(step [||s||] stop (\a s -> U.bool (f a) (yield a s) [||go $$s||]))
   in  go $$s ||]

filter :: (Up a -> Up Bool) -> Pull a -> Pull a
filter f pa = do
  Pull' _ seed step <- pa
  pure $ Pull' Nothing seed (find# f step)

take :: Up Int -> Pull a -> Pull a
take n pa = do
  Pull' len seed step <- pa
  pure $ Pull' (U.max <$> Just n <*> len) (U.pair seed n) \s stop yield -> [||
          case $$s of
            U.Pair s n ->
              if (n ::Int) <= 0
                 then $$stop
                 else $$(step [||s||] stop (\a s -> yield a (U.pair s ([||n||]-1))))
          ||]

foldl# :: (Up b -> Up a -> Up b) -> Up b -> Pull' a -> Up b
foldl# f b (Pull' _ seed step) =
  [|| let go s b = seq b $$(step [||s||] [||b||] (\a s -> [|| go $$s $$(f [||b||] a) ||]))
      in go $$seed $$b ||]

foldl :: (Up b -> Up a -> Up b) -> Up b -> Pull a -> Up b
foldl f b pa = run (pure . foldl# f b =<< pa)

sum :: (U.Num a) => Pull a -> Up a
sum = Pull2.foldl (+) 0

product :: (U.Num a) => Pull a -> Up a
product = Pull2.foldl (*) 0

takeWhile :: (Up a -> Up Bool) -> Pull a -> Pull a
takeWhile f pa = do
  Pull' _ seed step <- pa
  pure $ Pull' Nothing seed \s stop yield -> step s stop \a s -> U.bool (f a) (yield a s) stop

dropWhile# :: (Up a -> Up Bool) -> (Up s -> Step a s) -> Up s -> Gen (Up s)
dropWhile# f step s = Gen \ret -> [||
   let go s = $$(step [||s||] (ret [||s||]) (\a s -> U.bool (f a) [||go $$s||] (ret s)))
   in  go $$s ||]

dropWhile :: (Up a -> Up Bool) -> Pull a -> Pull a
dropWhile f pa = do
  Pull' _ seed step <- pa
  seed <- dropWhile# f step seed
  pure $ Pull' Nothing seed step

fromList :: Up [a] -> Pull a
fromList as = pure $
  Pull' (Just [||Prelude.length $$as||]) as \s stop yield ->
    [|| case $$s of []   -> $$stop
                    a:as -> $$(yield [||a||] [||as||]) ||]

length :: Pull a -> Up Int
length as = run do
  as <- as
  case len as of
    Nothing  -> pure $ foldl# (\acc _ -> acc + 1) 0 as
    Just len -> pure len

toList :: Pull a -> Up [a]
toList pa = run do
  Pull' len seed step <- pa
  pure [|| let go s = seq s ($$(step [||s||] [||[]||] (\ a s -> [|| $$a : go $$s ||])))
           in go $$seed ||]

toList' :: Pull a -> Up [a]
toList' pa = run do
  Pull' len seed step <- pa
  pure [|| let go s = seq s ($$(step [||s||] [||[]||] (\ a s -> [|| ((:) $! $$a) $! (go $$s) ||])))
           in go $$seed ||]

fromAFI :: forall a. Flat a => Up (AFI.Array a) -> Pull a
fromAFI as =
  ilet' as \as ->
  ilet' [|| AFI.size $$as ||] \size ->
  pure $ Pull' (Just size) (U.tup3 as (0 :: Up Int) size) \s stop yield ->
    [|| case $$s of
          U.Tup3 as i size -> if i < (size ::Int)
            then let a = as AFI.! i
                 in seq a $$(yield [||a||] (U.tup3 [||as||] ([||i||] + 1) [||size||]))
            else $$stop
     ||]

fromALI :: forall a. Flat a => Up (ALI.Array a) -> Pull a
fromALI as =
  ilet' as \as ->
  ilet' [|| ALI.size $$as ||] \size ->
  pure $ Pull' (Just size) (U.tup3 as (0 :: Up Int) size) \s stop yield ->
    [|| case $$s of
          U.Tup3 as i size -> if i < (size ::Int)
            then let a = as ALI.! i
                 in seq a $$(yield [||a||] (U.tup3 [||as||] ([||i||] + 1) [||size||]))
            else $$stop
     ||]

data W = W !(State# RealWorld)
data ToAFI a = ToAFI !(AFM.Array a) !Int !(State# RealWorld)
data ToALI a = ToALI !(ALM.Array a) !Int !(State# RealWorld)

toAFI :: forall a. Flat a => Pull a -> Up (AFI.Array a)
toAFI as = run do
  Pull' len seed step <- as
  case len of

    Nothing ->
      pure [||
        let go s len w = $$(step [||s||]
             [|| case unIO (AFM.new len) w of
                   (# w, marr #) -> ToAFI marr len w
              ||]
             \a s -> [||
                let x = $$a;
                in case go $$s (len + 1) w of
                  ToAFI marr len w ->
                    let len' = len - 1
                    in case unIO (AFM.write marr len' x) w of
                      (# w, _ #) -> ToAFI marr len' w
                       ||]
             )
        in AFI.Array (runRW# \w -> case go $$seed 0 w of
             ToAFI arr _ w -> case unIO (AFM.unsafeFreeze arr) w of
               (# _, AFI.Array arr #) -> arr)
        ||]

    Just len ->
      pure [||
        let go marr s i w = $$(step [||s||]
              [||W w||]
              \a s -> [||
                case unIO (AFM.write marr i $$a) w of
                  (# w, _ #) -> go marr $$s (i + 1) w
                ||])

            cont len = AFI.Array (runRW# \w -> case unIO (AFM.new len) w of
              (# w, marr #) -> case go marr $$seed 0 w of
                W w -> case unIO (AFM.unsafeFreeze marr) w of
                  (# _, AFI.Array arr #) -> arr)

        in cont $! $$len
      ||]

toALI :: forall a. Flat a => Pull a -> Up (ALI.Array a)
toALI as = run do
  Pull' len seed step <- as
  case len of

    Nothing ->
      pure [||
        let go s len w = $$(step [||s||]
             [|| case unIO (ALM.new len undefElem) w of
                   (# w, marr #) -> ToALI marr len w
              ||]
             \a s -> [||
                let x = $$a;
                in case go $$s (len + 1) w of
                  ToALI marr len w ->
                    let len' = len - 1
                    in case unIO (ALM.write marr len' x) w of
                      (# w, _ #) -> ToALI marr len' w
                       ||]
             )
        in ALI.Array (runRW# \w -> case go $$seed 0 w of
             ToALI arr _ w -> case unIO (ALM.unsafeFreeze arr) w of
               (# _, ALI.Array arr #) -> arr)
        ||]

    Just len ->
      pure [||
        let go marr s i w = $$(step [||s||]
              [||W w||]
              \a s -> [||
                case unIO (ALM.write marr i $$a) w of
                  (# w, _ #) -> go marr $$s (i + 1) w
                ||])

            cont len = ALI.Array (runRW# \w -> case unIO (ALM.new len undefElem) w of
              (# w, marr #) -> case go marr $$seed 0 w of
                W w -> case unIO (ALM.unsafeFreeze marr) w of
                  (# _, ALI.Array arr #) -> arr)

        in cont $! $$len
      ||]