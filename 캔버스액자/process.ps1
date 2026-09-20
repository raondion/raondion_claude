Add-Type -AssemblyName System.Drawing

$src = @"
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Threading.Tasks;

public static class PhotoTool
{
    // ---------- helpers ----------
    static Bitmap ToArgb32(Bitmap src)
    {
        if (src.PixelFormat == PixelFormat.Format32bppArgb) return (Bitmap)src.Clone();
        Bitmap bmp = new Bitmap(src.Width, src.Height, PixelFormat.Format32bppArgb);
        using (Graphics g = Graphics.FromImage(bmp))
        {
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.DrawImage(src, 0, 0, src.Width, src.Height);
        }
        return bmp;
    }

    static byte[] GetBytes(Bitmap bmp, out int stride)
    {
        Rectangle rect = new Rectangle(0, 0, bmp.Width, bmp.Height);
        BitmapData bd = bmp.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        stride = bd.Stride;
        byte[] data = new byte[stride * bmp.Height];
        Marshal.Copy(bd.Scan0, data, 0, data.Length);
        bmp.UnlockBits(bd);
        return data;
    }

    static Bitmap FromBytes(byte[] data, int width, int height, int stride)
    {
        Bitmap bmp = new Bitmap(width, height, PixelFormat.Format32bppArgb);
        Rectangle rect = new Rectangle(0, 0, width, height);
        BitmapData bd = bmp.LockBits(rect, ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
        Marshal.Copy(data, 0, bd.Scan0, data.Length);
        bmp.UnlockBits(bd);
        return bmp;
    }

    static byte Clamp(double v)
    {
        if (v < 0) return 0;
        if (v > 255) return 255;
        return (byte)v;
    }

    // ---------- 0. normalize EXIF orientation into actual pixel data ----------
    const int OrientationId = 0x0112;
    public static Bitmap ApplyExifOrientation(Bitmap bmp)
    {
        if (Array.IndexOf(bmp.PropertyIdList, OrientationId) < 0) return bmp;
        PropertyItem prop = bmp.GetPropertyItem(OrientationId);
        int val = prop.Value[0];
        RotateFlipType flip = RotateFlipType.RotateNoneFlipNone;
        switch (val)
        {
            case 1: flip = RotateFlipType.RotateNoneFlipNone; break;
            case 2: flip = RotateFlipType.RotateNoneFlipX; break;
            case 3: flip = RotateFlipType.Rotate180FlipNone; break;
            case 4: flip = RotateFlipType.Rotate180FlipX; break;
            case 5: flip = RotateFlipType.Rotate90FlipX; break;
            case 6: flip = RotateFlipType.Rotate90FlipNone; break;
            case 7: flip = RotateFlipType.Rotate270FlipX; break;
            case 8: flip = RotateFlipType.Rotate270FlipNone; break;
        }
        if (flip != RotateFlipType.RotateNoneFlipNone) bmp.RotateFlip(flip);
        bmp.RemovePropertyItem(OrientationId);
        return bmp;
    }

    // ---------- 1. crop to target ratio (width:height), keep native resolution ----------
    public static Bitmap CropToRatio(Bitmap srcIn, double ratio, double anchorFrac)
    {
        int w = srcIn.Width, h = srcIn.Height;
        double curRatio = (double)w / h;
        int cw, ch, cx, cy;
        if (curRatio > ratio)
        {
            // too wide -> crop width, keep full height
            ch = h;
            cw = (int)Math.Round(h * ratio);
            int centerX = (int)Math.Round(anchorFrac * w);
            cx = centerX - cw / 2;
            if (cx < 0) cx = 0;
            if (cx + cw > w) cx = w - cw;
            cy = 0;
        }
        else
        {
            // too tall -> crop height, keep full width
            cw = w;
            ch = (int)Math.Round(w / ratio);
            int centerY = (int)Math.Round(anchorFrac * h);
            cy = centerY - ch / 2;
            if (cy < 0) cy = 0;
            if (cy + ch > h) cy = h - ch;
            cx = 0;
        }
        Bitmap outBmp = new Bitmap(cw, ch, PixelFormat.Format32bppArgb);
        using (Graphics g = Graphics.FromImage(outBmp))
        {
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.DrawImage(srcIn, new Rectangle(0, 0, cw, ch), new Rectangle(cx, cy, cw, ch), GraphicsUnit.Pixel);
        }
        return outBmp;
    }

    // ---------- 1b. extend canvas (no cropping) to reach target ratio, padding top/bottom
    //              by stretching+blurring a small "safe" background strip (no faces/subjects)
    //              near each edge, so nobody gets cut off and no face gets duplicated ----------
    public static Bitmap ExtendVerticalToRatio(Bitmap srcIn, double ratio, double topShare, int topSafeStrip, int bottomSafeStrip)
    {
        int w = srcIn.Width, h = srcIn.Height;
        int newH = (int)Math.Round(w / ratio);
        if (newH <= h) return CropToRatio(srcIn, ratio, 0.5);

        int totalExtra = newH - h;
        int topExtra = (int)Math.Round(totalExtra * topShare);
        int bottomExtra = totalExtra - topExtra;

        Bitmap srcArgb = ToArgb32(srcIn);

        Bitmap canvas = new Bitmap(w, newH, PixelFormat.Format32bppArgb);
        using (Graphics g = Graphics.FromImage(canvas))
        {
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.Clear(Color.Black);

            if (topExtra > 0)
            {
                int stripH = Math.Min(topSafeStrip, h);
                using (Bitmap strip = CropRect(srcArgb, new Rectangle(0, 0, w, stripH)))
                {
                    strip.RotateFlip(RotateFlipType.RotateNoneFlipY); // last row of strip now == src row 0 (seam match)
                    using (Bitmap stretched = ResizeTo(strip, w, topExtra))
                    {
                        Bitmap blurred = SimpleBlur(stretched, 30);
                        g.DrawImage(blurred, 0, 0);
                        blurred.Dispose();
                    }
                }
            }

            g.DrawImage(srcArgb, 0, topExtra, w, h);

            if (bottomExtra > 0)
            {
                int stripH = Math.Min(bottomSafeStrip, h);
                using (Bitmap strip = CropRect(srcArgb, new Rectangle(0, h - stripH, w, stripH)))
                {
                    strip.RotateFlip(RotateFlipType.RotateNoneFlipY); // first row of strip now == src last row (seam match)
                    using (Bitmap stretched = ResizeTo(strip, w, bottomExtra))
                    {
                        Bitmap blurred = SimpleBlur(stretched, 30);
                        g.DrawImage(blurred, 0, topExtra + h);
                        blurred.Dispose();
                    }
                }
            }
        }
        srcArgb.Dispose();
        return canvas;
    }

    static Bitmap ResizeTo(Bitmap src, int w, int h)
    {
        Bitmap outBmp = new Bitmap(w, h, PixelFormat.Format32bppArgb);
        using (Graphics g = Graphics.FromImage(outBmp))
        {
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.DrawImage(src, 0, 0, w, h);
        }
        return outBmp;
    }

    static Bitmap CropRect(Bitmap src, Rectangle rect)
    {
        Bitmap outBmp = new Bitmap(rect.Width, rect.Height, PixelFormat.Format32bppArgb);
        using (Graphics g = Graphics.FromImage(outBmp))
        {
            g.DrawImage(src, new Rectangle(0, 0, rect.Width, rect.Height), rect, GraphicsUnit.Pixel);
        }
        return outBmp;
    }

    static Bitmap SimpleBlur(Bitmap bmp, int radius)
    {
        int stride;
        byte[] data = GetBytes(bmp, out stride);
        byte[] blurred = BoxBlur(data, bmp.Width, bmp.Height, stride, radius, 2);
        return FromBytes(blurred, bmp.Width, bmp.Height, stride);
    }

    // ---------- 2. auto tone correction + saturation + mild sharpen ----------
    public static Bitmap ColorCorrect(Bitmap srcIn)
    {
        Bitmap src = ToArgb32(srcIn);
        int w = src.Width, h = src.Height;
        int stride;
        byte[] data = GetBytes(src, out stride);
        int n = w * h;

        // histogram per channel for percentile stretch
        int[] histR = new int[256]; int[] histG = new int[256]; int[] histB = new int[256];
        for (int y = 0; y < h; y++)
        {
            int row = y * stride;
            for (int x = 0; x < w; x++)
            {
                int i = row + x * 4;
                histB[data[i]]++; histG[data[i + 1]]++; histR[data[i + 2]]++;
            }
        }
        int lowClip = (int)(n * 0.006);
        int highClip = (int)(n * 0.006);
        int loR = Percentile(histR, lowClip), hiR = 255 - Percentile(ReverseArr(histR), highClip);
        int loG = Percentile(histG, lowClip), hiG = 255 - Percentile(ReverseArr(histG), highClip);
        int loB = Percentile(histB, lowClip), hiB = 255 - Percentile(ReverseArr(histB), highClip);
        if (hiR - loR < 40) { loR = Math.Max(0, loR - 20); hiR = Math.Min(255, hiR + 20); }
        if (hiG - loG < 40) { loG = Math.Max(0, loG - 20); hiG = Math.Min(255, hiG + 20); }
        if (hiB - loB < 40) { loB = Math.Max(0, loB - 20); hiB = Math.Min(255, hiB + 20); }

        double satBoost = 1.15;
        double contrast = 1.06;
        double brightAdd = 4.0;

        byte[] outData = new byte[data.Length];
        Parallel.For(0, h, y =>
        {
            int row = y * stride;
            for (int x = 0; x < w; x++)
            {
                int i = row + x * 4;
                double b = Stretch(data[i], loB, hiB);
                double g = Stretch(data[i + 1], loG, hiG);
                double r = Stretch(data[i + 2], loR, hiR);

                // contrast around mid-gray
                r = (r - 128) * contrast + 128 + brightAdd;
                g = (g - 128) * contrast + 128 + brightAdd;
                b = (b - 128) * contrast + 128 + brightAdd;

                // saturation boost (based on luminance)
                double lum = 0.299 * r + 0.587 * g + 0.114 * b;
                r = lum + (r - lum) * satBoost;
                g = lum + (g - lum) * satBoost;
                b = lum + (b - lum) * satBoost;

                outData[i] = Clamp(b);
                outData[i + 1] = Clamp(g);
                outData[i + 2] = Clamp(r);
                outData[i + 3] = data[i + 3];
            }
        });

        Bitmap toned = FromBytes(outData, w, h, stride);
        src.Dispose();
        Bitmap sharpened = UnsharpMask(toned, 1.2, 0.35);
        toned.Dispose();
        return sharpened;
    }

    static int[] ReverseArr(int[] a)
    {
        int[] r = new int[256];
        for (int i = 0; i < 256; i++) r[i] = a[255 - i];
        return r;
    }

    static int Percentile(int[] hist, int clip)
    {
        int cum = 0;
        for (int v = 0; v < 256; v++)
        {
            cum += hist[v];
            if (cum > clip) return v;
        }
        return 255;
    }

    static double Stretch(byte v, int lo, int hi)
    {
        if (hi <= lo) return v;
        double t = (v - lo) * 255.0 / (hi - lo);
        return t;
    }

    // simple unsharp mask using box-blur approximation of gaussian
    static Bitmap UnsharpMask(Bitmap srcIn, double radius, double amount)
    {
        int w = srcIn.Width, h = srcIn.Height;
        int stride;
        byte[] data = GetBytes(srcIn, out stride);
        byte[] blurred = BoxBlur(data, w, h, stride, (int)Math.Max(1, radius), 2);

        byte[] outData = new byte[data.Length];
        Parallel.For(0, h, y =>
        {
            int row = y * stride;
            for (int x = 0; x < w; x++)
            {
                int i = row + x * 4;
                for (int c = 0; c < 3; c++)
                {
                    double orig = data[i + c];
                    double bl = blurred[i + c];
                    double val = orig + (orig - bl) * amount;
                    outData[i + c] = Clamp(val);
                }
                outData[i + 3] = data[i + 3];
            }
        });
        return FromBytes(outData, w, h, stride);
    }

    // separable box blur repeated `passes` times (approximates gaussian), operates on BGRA byte array
    static byte[] BoxBlur(byte[] src, int w, int h, int stride, int radius, int passes)
    {
        byte[] cur = (byte[])src.Clone();
        for (int p = 0; p < passes; p++)
        {
            cur = BoxBlurHoriz(cur, w, h, stride, radius);
            cur = BoxBlurVert(cur, w, h, stride, radius);
        }
        return cur;
    }

    static byte[] BoxBlurHoriz(byte[] src, int w, int h, int stride, int radius)
    {
        byte[] outp = new byte[src.Length];
        Parallel.For(0, h, y =>
        {
            int row = y * stride;
            for (int c = 0; c < 3; c++)
            {
                int sum = 0; int count = 0;
                for (int x = -radius; x <= radius; x++)
                {
                    int xx = Math.Min(w - 1, Math.Max(0, x));
                    sum += src[row + xx * 4 + c]; count++;
                }
                for (int x = 0; x < w; x++)
                {
                    outp[row + x * 4 + c] = (byte)(sum / count);
                    int addX = Math.Min(w - 1, x + radius + 1);
                    int subX = Math.Max(0, x - radius);
                    sum += src[row + addX * 4 + c] - src[row + subX * 4 + c];
                }
            }
            // alpha passthrough
            for (int x = 0; x < w; x++) outp[row + x * 4 + 3] = src[row + x * 4 + 3];
        });
        return outp;
    }

    static byte[] BoxBlurVert(byte[] src, int w, int h, int stride, int radius)
    {
        byte[] outp = new byte[src.Length];
        Parallel.For(0, w, x =>
        {
            for (int c = 0; c < 3; c++)
            {
                int sum = 0; int count = 0;
                for (int y = -radius; y <= radius; y++)
                {
                    int yy = Math.Min(h - 1, Math.Max(0, y));
                    sum += src[yy * stride + x * 4 + c]; count++;
                }
                for (int y = 0; y < h; y++)
                {
                    outp[y * stride + x * 4 + c] = (byte)(sum / count);
                    int addY = Math.Min(h - 1, y + radius + 1);
                    int subY = Math.Max(0, y - radius);
                    sum += src[addY * stride + x * 4 + c] - src[subY * stride + x * 4 + c];
                }
            }
            for (int y = 0; y < h; y++) outp[y * stride + x * 4 + 3] = src[y * stride + x * 4 + 3];
        });
        return outp;
    }

    // ---------- 3. colored pencil sketch ----------
    public static Bitmap PencilSketch(Bitmap srcIn)
    {
        Bitmap src = ToArgb32(srcIn);
        int w = src.Width, h = src.Height;
        int stride;
        byte[] data = GetBytes(src, out stride);
        int n = w * h;

        byte[] gray = new byte[data.Length];
        byte[] invGray = new byte[data.Length];
        Parallel.For(0, h, y =>
        {
            int row = y * stride;
            for (int x = 0; x < w; x++)
            {
                int i = row + x * 4;
                double g = 0.299 * data[i + 2] + 0.587 * data[i + 1] + 0.114 * data[i];
                byte gb = Clamp(g);
                gray[i] = gray[i + 1] = gray[i + 2] = gb;
                gray[i + 3] = 255;
                byte ib = Clamp(255 - g);
                invGray[i] = invGray[i + 1] = invGray[i + 2] = ib;
                invGray[i + 3] = 255;
            }
        });

        int radius = Math.Max(4, Math.Min(w, h) / 90);
        byte[] blurInv = BoxBlur(invGray, w, h, stride, radius, 3);

        // dodge blend: sketch = gray * 255 / (255 - blurInv)
        byte[] sketch = new byte[data.Length];
        Parallel.For(0, h, y =>
        {
            int row = y * stride;
            for (int x = 0; x < w; x++)
            {
                int i = row + x * 4;
                double g = gray[i];
                double b = blurInv[i];
                double denom = 255.0 - b;
                if (denom < 1) denom = 1;
                double val = g * 255.0 / denom;
                byte vb = Clamp(val);
                sketch[i] = sketch[i + 1] = sketch[i + 2] = vb;
                sketch[i + 3] = 255;
            }
        });

        // soft color base: desaturate slightly, brighten, heavy blur for pencil "shading" patches
        byte[] colorBase = new byte[data.Length];
        Parallel.For(0, h, y =>
        {
            int row = y * stride;
            for (int x = 0; x < w; x++)
            {
                int i = row + x * 4;
                double b = data[i], g = data[i + 1], r = data[i + 2];
                double lum = 0.299 * r + 0.587 * g + 0.114 * b;
                double sat = 0.72;
                double bright = 18;
                double rr = lum + (r - lum) * sat + bright;
                double gg = lum + (g - lum) * sat + bright;
                double bb = lum + (b - lum) * sat + bright;
                colorBase[i] = Clamp(bb);
                colorBase[i + 1] = Clamp(gg);
                colorBase[i + 2] = Clamp(rr);
                colorBase[i + 3] = 255;
            }
        });
        int blurRadius2 = Math.Max(3, Math.Min(w, h) / 140);
        colorBase = BoxBlur(colorBase, w, h, stride, blurRadius2, 2);

        // combine: multiply colorBase with sketch(normalized), then blend a bit of paper white + slight texture
        Random rnd = new Random(12345);
        byte[] outData = new byte[data.Length];
        for (int y = 0; y < h; y++)
        {
            int row = y * stride;
            for (int x = 0; x < w; x++)
            {
                int i = row + x * 4;
                double sVal = sketch[i] / 255.0;
                for (int c = 0; c < 3; c++)
                {
                    double cb = colorBase[i + c];
                    double mult = cb * sVal;
                    // lighten slightly toward paper white to keep airy pencil feel
                    double val = mult * 0.86 + 255 * 0.06;
                    // subtle grain
                    double noise = (rnd.NextDouble() - 0.5) * 6.0;
                    val += noise;
                    outData[i + c] = Clamp(val);
                }
                outData[i + 3] = 255;
            }
        }

        Bitmap result = FromBytes(outData, w, h, stride);
        src.Dispose();
        return result;
    }

    // ---------- save as high quality jpeg ----------
    public static void SaveJpeg(Bitmap bmp, string path, long quality)
    {
        ImageCodecInfo jpegCodec = null;
        foreach (ImageCodecInfo ci in ImageCodecInfo.GetImageEncoders())
        {
            if (ci.FormatID == ImageFormat.Jpeg.Guid) { jpegCodec = ci; break; }
        }
        EncoderParameters ep = new EncoderParameters(1);
        ep.Param[0] = new EncoderParameter(Encoder.Quality, quality);
        bmp.Save(path, jpegCodec, ep);
    }
}
"@

Add-Type -TypeDefinition $src -ReferencedAssemblies System.Drawing

$root = "C:\Users\deobi\Desktop\raondion_claude\캔버스액자"
$srcDir = Join-Path $root "원본사진"
$correctedDir = Join-Path $root "수정사진\사진보정"
$sketchDir = Join-Path $root "수정사진\색연필느낌"

# files that must NOT be cropped horizontally (everyone would no longer fit) -> extend canvas instead
# value = share of the extra height added above the photo (rest goes below)
$extendFiles = @{
    "KakaoTalk_20260919_083814630.jpg" = 0.85
}

# file -> anchor fraction (position of crop-window center along the dimension being cropped)
$anchors = @{
    "KakaoTalk_20260919_083814630_01.jpg" = 0.62   # portrait -> vertical anchor
    "KakaoTalk_20260919_083814630_02.jpg" = 0.55
    "KakaoTalk_20260919_083814630_03.jpg" = 0.42
    "KakaoTalk_20260919_083814630_04.jpg" = 0.62
    "KakaoTalk_20260919_083814630_05.jpg" = 0.62
    "KakaoTalk_20260919_083814630_06.jpg" = 0.48   # landscape mural -> horizontal anchor
    "KakaoTalk_20260919_083814630_07.jpg" = 0.58
    "KakaoTalk_20260919_083814630_08.jpg" = 0.62
    "KakaoTalk_20260919_083814630_09.jpg" = 0.58
    "KakaoTalk_20260919_083814630_10.jpg" = 0.62
}

$ratio = 4.0 / 5.0

$allFiles = @{}
foreach ($k in $extendFiles.Keys) { $allFiles[$k] = $true }
foreach ($k in $anchors.Keys) { $allFiles[$k] = $true }

foreach ($fileName in $allFiles.Keys) {
    $inPath = Join-Path $srcDir $fileName
    if (-not (Test-Path $inPath)) { Write-Host "MISSING: $inPath"; continue }

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
    Write-Host "Processing $fileName ..."

    $orig = [System.Drawing.Bitmap]::FromFile($inPath)
    $orig = [PhotoTool]::ApplyExifOrientation($orig)

    if ($extendFiles.ContainsKey($fileName)) {
        $topShare = $extendFiles[$fileName]
        $cropped = [PhotoTool]::ExtendVerticalToRatio($orig, $ratio, $topShare, 550, 70)
    } else {
        $anchor = $anchors[$fileName]
        $cropped = [PhotoTool]::CropToRatio($orig, $ratio, $anchor)
    }
    $orig.Dispose()

    $corrected = [PhotoTool]::ColorCorrect($cropped)
    $correctedPath = Join-Path $correctedDir ($baseName + "_보정_400x500.jpg")
    [PhotoTool]::SaveJpeg($corrected, $correctedPath, 95)
    Write-Host "  -> $correctedPath ($($corrected.Width)x$($corrected.Height))"

    $sketch = [PhotoTool]::PencilSketch($corrected)
    $sketchPath = Join-Path $sketchDir ($baseName + "_색연필_400x500.jpg")
    [PhotoTool]::SaveJpeg($sketch, $sketchPath, 95)
    Write-Host "  -> $sketchPath"

    $cropped.Dispose()
    $corrected.Dispose()
    $sketch.Dispose()
}

Write-Host "DONE"
