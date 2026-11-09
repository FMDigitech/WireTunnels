using ZXing;
using ZXing.Common;

namespace WireTunnels.Client;

/// Port of QRCodeService.decode: the text of a QR code in an image. The app decodes the image file or the
/// clipboard bitmap to BGRA pixels; this stays platform-neutral so it is tested on any OS.
public static class QrCode
{
    public static string? Decode(byte[] bgra, int width, int height)
    {
        var reader = new BarcodeReaderGeneric
        {
            AutoRotate = true,
            Options = new DecodingOptions { PossibleFormats = [BarcodeFormat.QR_CODE], TryHarder = true, TryInverted = true },
        };
        var result = reader.Decode(new RGBLuminanceSource(bgra, width, height, RGBLuminanceSource.BitmapFormat.BGRA32));
        return string.IsNullOrEmpty(result?.Text) ? null : result.Text;
    }
}
