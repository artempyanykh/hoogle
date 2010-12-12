-- Recipe actions:
-- Download to foo.src in most cases, then extract to foo.txt, which can later be compiled to foo.hoo
module Recipe.All(recipes) where

import General.Base
import General.System
import Control.Concurrent
import qualified Data.Map as Map

import Recipe.Type
import Recipe.Download
import Recipe.Keyword
import Recipe.General
import Recipe.Hackage


-- CmdLine is guaranteed to be a constructor of type Data
recipes :: CmdLine -> IO ()
recipes opt = do
    hSetBuffering stdout NoBuffering
    createDirectoryIfMissing True $ datadir opt
    withDirectory (datadir opt) $ do
        resetErrors
        download opt
        let ys = parseRules $ actions opt
        make opt (filter (not . null . snd) ys) (map fst ys)
        recapErrors
        putStrLn "Data generation complete"


-- If I switch to the parallel-io library then it segfaults, due to GHC bug:
-- http://hackage.haskell.org/trac/ghc/ticket/4835 
withPool i f = f ()
extraWorkerWhileBlocked _ = id
parallel_ _ = sequence_


data Status = Built | Building (MVar ())

make :: CmdLine -> [(Name,[Name])] -> [Name] -> IO ()
make opt rules xs = withPool (error $ show $ threads opt) $ \pool -> do
    ref <- newMVar Map.empty
    fs ref pool [] xs
    where
        fs ref pool rec xs = parallel_ pool $ map (f ref pool rec) xs

        f ref pool rec x
            | x `elem` rec = putStrLn $ "Warning: Package database appears to be recursive, " ++ x
            | otherwise = join $ modifyMVar ref $ \mp -> case Map.lookup x mp of
                Just Built -> return (mp, return ())
                Just (Building v) -> return $ (,) mp $
                    extraWorkerWhileBlocked pool $ readMVar v
                Nothing -> do
                    v <- newEmptyMVar
                    return $ (,) (Map.insert x (Building v) mp) $ do
                        build (fs ref pool $ x:rec) opt rules x
                        modifyMVar_ ref $ \mp -> return $ Map.insert x Built mp
                        putMVar v ()


build :: ([Name] -> IO ()) -> CmdLine -> [(Name,[Name])] -> Name -> IO ()
build makeRec opt rules x = do
    putStrLn $ "Starting " ++ x
    case lookup x rules of
        Just ys -> combine makeRec x ys True
        _ -> case x of
            "keyword" -> makeKeyword
            "default" -> combine makeRec x ["keyword","package","platform"] False
            "platform" -> makePlatform makeRec
            "package" -> makePackage
            "all" -> makeAll makeRec
            _ -> makeDefault makeRec (local opt) x
    putStrLn $ "Finished " ++ x


parseRules :: [String] -> [(Name,[Name])]
parseRules [] = [("default",[])]
parseRules xs = map parseRule xs


parseRule :: String -> (Name,[Name])
parseRule x = (a, uncommas $ drop 1 b)
    where (a,b) = break (== '=') x
          uncommas = words . map (\x -> if x == ',' then ' ' else x)
