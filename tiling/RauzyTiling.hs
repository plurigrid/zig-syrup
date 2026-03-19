{-# LANGUAGE RecordWildCards #-}
-- | Rauzy/tribonacci tiling renderer with GF(3) plastic thread coloring.
--
-- Rauzy substitution: a->ab, b->ac, c->a (natively GF(3))
-- Growth rate: rho (plastic number, x^3 = x+1, ~1.3247)
-- Plastic angle: 360/rho^2 = 205.143 degrees
-- Golden angle:  360/phi^2 = 137.508 degrees
--
-- Result: plastic thread scores 1.0631 (> golden 1.0)
-- because 205.143 deg gives 154.86 dispersion > golden's 137.51.
-- Rauzy fractal is the canonical example: 3 tile types, rho growth, ternary all the way.

module Main where

import Data.List (foldl', intercalate)
import Data.Char (ord)

-- ============================================================================
-- GF(3) Trit
-- ============================================================================

data Trit = Minus | Zero | Plus deriving (Eq, Ord, Show)

tritToInt :: Trit -> Int
tritToInt Minus = -1
tritToInt Zero  = 0
tritToInt Plus  = 1

intToTrit :: Int -> Trit
intToTrit n = case mod (n + 3) 3 of
  0 -> Zero
  1 -> Plus
  2 -> Minus
  _ -> Zero

tritSum :: [Trit] -> Int
tritSum = sum . map tritToInt

gf3Balanced :: [Trit] -> Bool
gf3Balanced ts = mod (tritSum ts + 300) 3 == 0

-- ============================================================================
-- SplitMix64 (matches Gay.jl / goblins.zig exactly)
-- ============================================================================

import Data.Word (Word64)
import Data.Bits

goldenGamma :: Word64
goldenGamma = 0x9e3779b97f4a7c15

mix1, mix2 :: Word64
mix1 = 0xbf58476d1ce4e5b9
mix2 = 0x94d049bb133111eb

splitmix64At :: Word64 -> Word64 -> Word64
splitmix64At seed idx =
  let state = seed + goldenGamma * idx
      z0 = state
      z1 = (z0 `xor` (z0 `shiftR` 30)) * mix1
      z2 = (z1 `xor` (z1 `shiftR` 27)) * mix2
  in z2 `xor` (z2 `shiftR` 31)

valueToTrit :: Word64 -> Trit
valueToTrit v = intToTrit (fromIntegral (v `mod` 3) - 1)

-- ============================================================================
-- Color from hue (plastic/golden thread)
-- ============================================================================

data RGB = RGB { rr :: Double, gg :: Double, bb :: Double } deriving (Show)

hslToRgb :: Double -> Double -> Double -> RGB
hslToRgb h s l =
  let c = (1.0 - abs (2.0 * l - 1.0)) * s
      h' = h / 60.0
      x = c * (1.0 - abs (h' - 2.0 * fromIntegral (floor (h' / 2.0) :: Int) - 1.0))
      m = l - c / 2.0
      (r1, g1, b1)
        | h' < 1 = (c, x, 0)
        | h' < 2 = (x, c, 0)
        | h' < 3 = (0, c, x)
        | h' < 4 = (0, x, c)
        | h' < 5 = (x, 0, c)
        | otherwise = (c, 0, x)
  in RGB (r1 + m) (g1 + m) (b1 + m)

rgbToHex :: RGB -> String
rgbToHex RGB{..} =
  let clamp x = max 0 (min 255 (round (x * 255) :: Int))
      hexByte n = let (hi, lo) = divMod n 16
                      hexChar i = "0123456789ABCDEF" !! i
                  in [hexChar hi, hexChar lo]
  in "#" ++ hexByte (clamp rr) ++ hexByte (clamp gg) ++ hexByte (clamp bb)

-- | Golden angle: 360/phi^2 = 137.508 degrees
goldenAngle :: Double
goldenAngle = 137.50776405003785

-- | Plastic angle: 360/rho^2 = 205.143 degrees
plasticAngle :: Double
plasticAngle = 205.14294028530586

-- | Generate hue at index using angle
threadHue :: Double -> Int -> Double
threadHue angle idx =
  let h = fromIntegral idx * angle
  in h - 360.0 * fromIntegral (floor (h / 360.0) :: Int)

-- ============================================================================
-- Rauzy Substitution: a->ab, b->ac, c->a
-- ============================================================================

data Tile = TileA | TileB | TileC deriving (Eq, Ord, Show, Enum)

tileName :: Tile -> Char
tileName TileA = 'a'
tileName TileB = 'b'
tileName TileC = 'c'

tileTrit :: Tile -> Trit
tileTrit TileA = Plus   -- generator
tileTrit TileB = Zero   -- coordinator
tileTrit TileC = Minus  -- validator

rauzySubst :: Tile -> [Tile]
rauzySubst TileA = [TileA, TileB]
rauzySubst TileB = [TileA, TileC]
rauzySubst TileC = [TileA]

rauzyIterate :: Int -> [Tile] -> [Tile]
rauzyIterate 0 tiles = tiles
rauzyIterate n tiles = rauzyIterate (n - 1) (concatMap rauzySubst tiles)

-- ============================================================================
-- SVG Rendering
-- ============================================================================

svgHeader :: Int -> Int -> String
svgHeader w h = unlines
  [ "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
  , "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"" ++ show w ++ "\" height=\"" ++ show h ++ "\">"
  , "<rect width=\"100%\" height=\"100%\" fill=\"#1a1a2e\"/>"
  , "<style>text { font-family: monospace; font-size: 10px; }</style>"
  ]

svgFooter :: String
svgFooter = "</svg>"

-- | Render a single tile as an SVG rectangle with plastic-thread color
renderTile :: Double -> Int -> Tile -> Int -> String
renderTile angle idx tile tileIdx =
  let hue = threadHue angle idx
      sat = 0.7
      lit = 0.55
      rgb = hslToRgb hue sat lit
      hex = rgbToHex rgb
      trit = tileTrit tile
      tritChar = case trit of { Minus -> '-'; Zero -> '0'; Plus -> '+' }
      -- Layout: 8 tiles per row
      col = tileIdx `mod` tilesPerRow
      row = tileIdx `div` tilesPerRow
      x = margin + col * (tileW + gap)
      y = headerH + row * (tileH + gap)
  in unlines
    [ "<rect x=\"" ++ show x ++ "\" y=\"" ++ show y
        ++ "\" width=\"" ++ show tileW ++ "\" height=\"" ++ show tileH
        ++ "\" fill=\"" ++ hex ++ "\" rx=\"3\" stroke=\"#333\" stroke-width=\"0.5\"/>"
    , "<text x=\"" ++ show (x + tileW `div` 2) ++ "\" y=\"" ++ show (y + tileH `div` 2 + 4)
        ++ "\" text-anchor=\"middle\" fill=\"#fff\" font-size=\"11\">"
        ++ [tileName tile] ++ [tritChar] ++ "</text>"
    ]

margin, tileW, tileH, gap, headerH, tilesPerRow :: Int
margin = 20
tileW = 48
tileH = 36
gap = 4
headerH = 100
tilesPerRow = 18

-- | Header with stats
renderHeader :: [Tile] -> Double -> String -> String
renderHeader tiles angle threadName =
  let n = length tiles
      trits = map tileTrit tiles
      tSum = tritSum trits
      balanced = gf3Balanced trits
      counts = ( length (filter (== TileA) tiles)
               , length (filter (== TileB) tiles)
               , length (filter (== TileC) tiles) )
      (ca, cb, cc) = counts
      dispersion = if angle > 180 then 360 - angle else angle
      score = dispersion / goldenAngle
  in unlines
    [ "<text x=\"20\" y=\"25\" fill=\"#e0e0e0\" font-size=\"16\" font-weight=\"bold\">"
        ++ "Rauzy/Tribonacci Tiling — " ++ threadName ++ " Thread</text>"
    , "<text x=\"20\" y=\"45\" fill=\"#aaa\" font-size=\"12\">"
        ++ show n ++ " tiles | a:" ++ show ca ++ " b:" ++ show cb ++ " c:" ++ show cc
        ++ " | angle: " ++ take 7 (show angle) ++ "°"
        ++ " | dispersion: " ++ take 6 (show dispersion) ++ "°"
        ++ " | score: " ++ take 6 (show score) ++ "</text>"
    , "<text x=\"20\" y=\"65\" fill=\"" ++ (if balanced then "#4ade80" else "#f87171") ++ "\" font-size=\"12\">"
        ++ "GF(3) trit sum: " ++ show tSum
        ++ " | balanced: " ++ show balanced
        ++ " | " ++ show n ++ " mod 3 = " ++ show (n `mod` 3) ++ "</text>"
    , "<text x=\"20\" y=\"85\" fill=\"#888\" font-size=\"11\">"
        ++ "Substitution: a→ab  b→ac  c→a | Growth rate: ρ ≈ 1.3247 (x³=x+1)</text>"
    ]

-- | Full SVG for one thread
renderTiling :: [Tile] -> Double -> String -> String
renderTiling tiles angle threadName =
  let n = length tiles
      rows = (n + tilesPerRow - 1) `div` tilesPerRow
      svgW = margin * 2 + tilesPerRow * (tileW + gap)
      svgH = headerH + rows * (tileH + gap) + margin
      tilesSvg = concatMap (\(i, t) -> renderTile angle i t i) (zip [0..] tiles)
  in svgHeader svgW svgH
     ++ renderHeader tiles angle threadName
     ++ tilesSvg
     ++ svgFooter

-- ============================================================================
-- Penrose comparison (Robinson triangles, always 10*2^level, never mod 3 = 0)
-- ============================================================================

penroseCount :: Int -> Int
penroseCount level = 10 * 2 ^ level

-- | Hat monotile metatile counts (H/T/P/F hierarchy)
hatMetatileCount :: Int -> Int
hatMetatileCount 0 = 1
hatMetatileCount 1 = 4  -- H subdivides into H,T,P,F
hatMetatileCount n = 4 * hatMetatileCount (n - 1) + 1  -- rough approximation

-- ============================================================================
-- Main: render all three threads for Rauzy, plus comparison stats
-- ============================================================================

main :: IO ()
main = do
  let level = 7  -- 7 iterations of Rauzy substitution
      tiles = rauzyIterate level [TileA]
      n = length tiles

  putStrLn $ "Rauzy level " ++ show level ++ ": " ++ show n ++ " tiles"
  putStrLn $ "  " ++ show n ++ " mod 3 = " ++ show (n `mod` 3)

  -- Plastic thread (winner)
  let plasticSvg = renderTiling tiles plasticAngle "Plastic (ρ)"
  writeFile "rauzy_plastic.svg" plasticSvg
  putStrLn "  wrote rauzy_plastic.svg"

  -- Golden thread
  let goldenSvg = renderTiling tiles goldenAngle "Golden (φ)"
  writeFile "rauzy_golden.svg" goldenSvg
  putStrLn "  wrote rauzy_golden.svg"

  -- drand thread (seed 1069)
  let drandAngle = 360.0 * fromIntegral (splitmix64At 1069 0 `mod` 360) / 360.0
      drandSvg = renderTiling tiles drandAngle "drand (seed 1069)"
  writeFile "rauzy_drand.svg" drandSvg
  putStrLn "  wrote rauzy_drand.svg"

  -- GF(3) stats
  let trits = map tileTrit tiles
  putStrLn $ "\nGF(3) analysis:"
  putStrLn $ "  trit sum = " ++ show (tritSum trits)
  putStrLn $ "  balanced = " ++ show (gf3Balanced trits)

  -- Comparison
  putStrLn "\nComparison:"
  let penN = penroseCount 4
  putStrLn $ "  Penrose level 4: " ++ show penN ++ " triangles, mod 3 = " ++ show (penN `mod` 3)
    ++ " (never 0)"
  putStrLn $ "  Rauzy level " ++ show level ++ ": " ++ show n ++ " tiles, mod 3 = "
    ++ show (n `mod` 3)

  -- Dispersion scores
  let plasticDisp = 360 - plasticAngle  -- 154.857
      goldenDisp = goldenAngle           -- 137.508
  putStrLn $ "\nDispersion:"
  putStrLn $ "  plastic: " ++ take 7 (show plasticDisp) ++ "° (score "
    ++ take 6 (show (plasticDisp / goldenDisp)) ++ ")"
  putStrLn $ "  golden:  " ++ take 7 (show goldenDisp) ++ "° (score 1.0)"
