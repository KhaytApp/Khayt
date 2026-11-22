# Makineler ve yazıcılar

Üzerinde bastığınız şey ve — birini bağladığınızda — şu an ne yaptığı.

## Makine eklemek

Bir makine bir kayıttır: adı, türü, tabla boyutu, neye mal olduğu ve
çalıştırmanın neye mal olduğu. Son ikisi, Khayt'in o makinede bir saatin ne
değerde olduğunu söylemesini sağlar.

## Bir yazıcıya bağlanmak

Bir makine yazıcının kendisine bağlanabilir. Khayt yedi protokol konuşur:

- **Moonraker / Klipper** — Snapmaker U1 dahil.
- **OctoPrint**
- **PrusaLink**
- **Duet**
- **Repetier**
- **Bambu** — yalnızca durum. Bambu artık uzaktan kontrol için kendi
  bağlayıcısını şart koşuyor.
- **Elegoo reçine (SDCP)**

Adresi ve anahtarı girin, **Dene**'ye basın; Khayt neyin yanıt verdiğini söyler.
Anahtar, deftere yazılmaz; Mac'in Anahtar Zinciri'nde mühürlenir.

## Canlı durum

Bağlı bir yazıcı neyi bastığını, ne kadarının tamamlandığını, sıcaklıkları ve ne
kadar süre kaldığını gösterir.

Bu okuma hakkında bilinmeye değer iki şey:

- **İlerleme, yazıcı söyleyebiliyorsa bayta göre değil, katmana göre
  hesaplanır.** Bir dosyadaki bayt konumu işin ölçüsü değildir — 31 MB'lık bir
  model, neredeyse %20 bittiğinde %0,7 gösterdi.
- **Kalan süre, dosya taşıyorsa dilimleyicinin tahminidir** ve yalnızca
  taşımıyorsa tahmin yoluyla hesaplanır.

## Yeri değişen bir yazıcı

Yönlendirici yeniden başladığında yazıcılar yeni adresler alır. Khayt daha önce
gördüğü bir makineyi kartının kendi seri numarasıyla tanır ve onu çevrimdışı
göstermek yerine yeni adresine kadar izler.

## Bir plakadan tek bir nesneyi bırakmak

Bir Klipper veya Moonraker yazıcısında, bir plakadaki tek bir nesne, plakanın
geri kalanı devam ederken atlanabilir — yerinden çıkmış tek parça için.

**Geri alınamaz.** Klipper, bir nesne bırakılırken atlanan katmanları yeniden
basmaz; bu yüzden yanlışlıkla bırakılan bir nesne hurdadır.
