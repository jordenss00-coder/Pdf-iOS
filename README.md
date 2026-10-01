# PDF Atölye — iOS

PDF Atölye'nin iPhone ve iPad uygulaması. **43 PDF aracının tamamı cihazda çalışır**; belgeler
hiçbir sunucuya gönderilmez, hesap ya da internet bağlantısı gerekmez.

## Araçlar

| Grup | İçerik |
|---|---|
| Düzenle ve ekle | PDF düzenleyici (metin, çizim, vurgu, şekil, ok, beyaz örtü, görsel, not, bağlantı), imza (çiz/yaz/fotoğraf, PFX/P12 dijital imza), filigran, sayfa numarası, üst/alt bilgi, kırpma |
| Metin ve formlar | Mevcut metni düzelt, bul ve değiştir, form doldur, form oluştur (alanları otomatik algıla), belge bilgileri |
| Sayfalar | Birleştir (yer imleriyle), böl (aralık/N sayfa/tümü/yer imi/boyut), sil, çıkar, sürükle-bırak düzenle, döndür, çoklu sayfa, sayfa boyutu |
| PDF'ten dönüştür | Word, Excel, PowerPoint, JPG/PNG (ya da gömülü görselleri çıkar), PDF/A, TXT/HTML, Markdown |
| PDF'e dönüştür | Görseller, Word, Excel, PowerPoint, Pages/Numbers/Keynote, HTML ve web adresi, kamerayla belge tarama |
| İyileştir | Sıkıştır, OCR (Türkçe/İngilizce, aranabilir PDF), onar, siyah-beyaz, düzleştir |
| Güvenlik | AES parola ve izinler, şifre kaldırma, gerçek karartma (TC kimlik, IBAN, telefon…), karşılaştırma |
| Yapay zekâ | Apple Intelligence ile cihazda özet ve düzeni koruyan çeviri (iOS 26+) |
| İş akışları | Numarala, sıkıştır, döndür, gri tonlama ve düzleştirmeden en fazla 8 adımlık kayıtlı akışlar |

## Mimari

- **Arayüz:** SwiftUI; araç kataloğu (`App/Model/Catalog.swift`) masaüstü sürümle aynı seçenek şemasını kullanır,
  seçenek formu otomatik oluşur. Düzenleyici PDFKit üzerine kuruludur.
- **Motor:** PDFKit (sayfa işlemleri), PDFium (metin, görsel ve içerik düzenleme; bkz. `Engine/PDFiumKit.swift`),
  Vision (OCR), VisionKit (tarama), WebKit (Office/HTML → PDF), Foundation Models (yapay zekâ), Security/CryptoKit (dijital imza).
  Office dosyaları, ZIP ve CMS imzaları bağımlılıksız Swift koduyla yazılır.
- **Testler:** `Tests/EngineTests.swift` her aracı gerçek PDF'lerle çalıştırıp sonucu ölçer.

## Mac olmadan geliştirme

Derleme ve testler GitHub Actions'ın macOS makinelerinde çalışır (`.github/workflows/ios.yml`):

1. `scripts/fetch-pdfium.sh` PDFium'un hazır iOS derlemelerini indirip `Vendor/PDFium.xcframework` paketine çevirir.
2. [XcodeGen](https://github.com/yonaskolb/XcodeGen) `project.yml` dosyasından Xcode projesini üretir.
3. Uygulama imzasız olarak cihaz için derlenir, motor testleri simülatörde çalışır, ekran görüntüleri alınır.

Örnek Office dosyaları `scripts/make-fixtures.py`, uygulama ikonu `scripts/make-icon.py` ile üretilir.
`Fixtures/test-sertifika.p12` yalnızca testlerde kullanılan, parolası belli (`test1234`) sahte bir sertifikadır.

## TestFlight

`TestFlight` iş akışı elle başlatılır (`gh workflow run TestFlight`). Codemagic CLI araçları App Store Connect
API anahtarıyla dağıtım sertifikasını ve profilini oluşturur ya da indirir, imzalı IPA'yı derler ve yükler.
Sürüm numarası iş akışının koşu numarasıdır.

Gereken GitHub secret'ları: `APP_STORE_CONNECT_ISSUER_ID`, `APP_STORE_CONNECT_KEY_IDENTIFIER`,
`APP_STORE_CONNECT_PRIVATE_KEY` (.p8 içeriği), `CERTIFICATE_PRIVATE_KEY` (dağıtım sertifikasının RSA anahtarı).
Kendi bilgisayarında `scripts/setup-testflight-secrets.sh` ile ayarlanabilir.

## Lisans

Tüm hakları saklıdır. Bu depo görünür olsa da kodun kullanımı, kopyalanması veya dağıtımı için izin verilmez.
Üçüncü taraf bileşenler kendi lisanslarıyla gelir: PDFium ve bağımlılıkları BSD/Apache/MIT türü izin verici
lisanslar kullanır; metinleri uygulamanın Hakkında ekranında yer alır.
