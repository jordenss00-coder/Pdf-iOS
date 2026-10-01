# PDF Atölye — iOS

PDF Atölye'nin iPhone ve iPad uygulaması. Belgeler cihazda işlenir; sunucuya gönderilmez.

**Durum:** teknik deneme. PDFKit, PDFium, Vision ve WebKit ile hangi araçların
cihazda yapılabildiği ölçülüyor. Uygulama henüz yalnızca PDF açıp gösteriyor.

## Mac olmadan geliştirme

Derleme ve testler GitHub Actions'ın macOS makinelerinde çalışır (`.github/workflows/ios.yml`):

1. `scripts/fetch-pdfium.sh` PDFium'un hazır iOS derlemelerini indirip
   `Vendor/PDFium.xcframework` paketine çevirir.
2. [XcodeGen](https://github.com/yonaskolb/XcodeGen) `project.yml` dosyasından Xcode projesini üretir.
3. Uygulama imzasız olarak cihaz için derlenir; teknik deneme testleri simülatörde çalışır.
4. Sonuçlar iş özetinde tablo olarak ve `ios-spike` çıktısında görünür.

Örnek Office dosyaları `scripts/make-fixtures.py` ile üretilir (`Fixtures/`).
Uygulama ikonu `scripts/make-icon.py` ile masaüstündeki marka işaretinden üretilir.

## TestFlight

`TestFlight` iş akışı elle başlatılır (`gh workflow run TestFlight`). Codemagic CLI
araçları App Store Connect API anahtarıyla dağıtım sertifikasını ve profilini
oluşturur ya da indirir, imzalı IPA'yı derler ve App Store Connect'e yükler.
Sürüm numarası iş akışının koşu numarasıdır.

Gereken GitHub secret'ları: `APP_STORE_CONNECT_ISSUER_ID`, `APP_STORE_CONNECT_KEY_IDENTIFIER`,
`APP_STORE_CONNECT_PRIVATE_KEY` (.p8 içeriği), `CERTIFICATE_PRIVATE_KEY`
(dağıtım sertifikasının RSA anahtarı; her koşuda aynı sertifika kullanılır).

## Klasörler

```text
App/       SwiftUI uygulaması
Spike/     Teknik deneme testleri
Fixtures/  Office → PDF denemesi için örnek dosyalar
scripts/   PDFium paketleme ve örnek dosya betikleri
```

## Lisans

Tüm hakları saklıdır. Bu depo görünür olsa da kodun kullanımı, kopyalanması veya
dağıtımı için izin verilmez. Üçüncü taraf bileşenler kendi lisanslarıyla gelir:
PDFium ve bağımlılıkları BSD/Apache/MIT türü izin verici lisanslar kullanır
(`Vendor/PDFium-licenses`, CI çıktısı).
