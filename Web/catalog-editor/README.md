# Yerel katalog editörü

Update Atlas'ın resmi katalog JSON'unu tablo ve ayrıntı panelinde düzenler. Node.js'in
yerleşik modüllerini kullanır; npm kurulumu, hesap veya barındırma gerektirmez.

Proje kökünden başlatın:

```sh
node Web/catalog-editor/server.mjs
```

Terminalde yazan `http://127.0.0.1:…/` adresini tarayıcıda açın. Editör, varsa
`Web/site/api/update-atlas/catalog-v1.json` dosyasını, yoksa uygulamanın paketlenmiş kataloğunu salt okunur
kaynak olarak kullanır. Başka bir kaynak seçmek için:

```sh
node Web/catalog-editor/server.mjs --source /tam/yol/catalog-v1.json
```

Arama veya destek filtresiyle kural bulun; sağ panelde alanları düzenleyin. Yedek
sağlayıcılar ve nadir alanlar için **Gelişmiş · kural JSON’u** bölümünü kullanın. İlk
değişiklik revizyonu hem kaynak hem paketlenmiş katalogdan yüksek bir değere çıkarır ve
`generatedAt` zamanını günceller. Mevcut ID'ler değiştirilemez; kurallar silinemez.

**Doğrula** şema, HTTPS, benzersiz ID, revizyon ve korunması gereken ID kontrollerini
çalıştırır. **Taslağı kaydet**, doğrulanmış veriyi proje içindeki özel taslak dosyasına
atomik olarak yazar.
Bu dosya gitignore kapsamındadır ve sonraki açılışta geri yüklenir. İki sekme aynı taslağı
değiştirirse eski sekmenin kaydı reddedilir. **JSON dışa aktar** aynı doğrulamadan sonra
tam katalog dosyasını indirir. Kaynak site dosyası ve paketlenmiş katalog editör tarafından
asla değiştirilmez.

İndirilen dosyayı mevcut [`stage_channel.py`](../../__Assets__/Scripts/Apple/stage_channel.py)
akışına `--catalog` olarak verin. Bu adım canlı siteyi güncellemez: ürün sitesindeki
değişiklik, içerik incelemesi, sahibin yayın onayı ve canlı SHA-256 karşılaştırması hâlâ
zorunludur. Breaking şema değişiklikleri bu v1 editörünün kapsamı dışındadır.

Sunucu yalnızca `127.0.0.1` üzerinde dinler, API yazma isteklerinde tek oturumluk token
ve aynı origin denetler, üçüncü taraf script veya servis kullanmaz. Durdurmak için terminalde
Ctrl-C kullanın.
