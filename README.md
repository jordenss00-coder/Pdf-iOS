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
