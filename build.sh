#!/bin/bash
# Buduje "Flashcards from File.app" ze zrodel w Sources/, sklada Flashcards-from-File.zip
# do pobrania i instaluje w /Applications.
# W Finderze, Docku i menu aplikacja nazywa sie w jezyku systemu: "Fiszki z pliku",
# "Flashcards from File", "Karteikarten aus Datei"...
set -euo pipefail
cd "$(dirname "$0")"

NAME="Flashcards from File"
EXEC="Flashcards"
ID="atyp.makers.fiszki.file"
ZIP="Flashcards-from-File.zip"
APP="/Applications/$NAME.app"
# Autor w okienku O programie, jak w aplikacjach Apple, z autorem zamiast Apple.
AUTHOR="EnderNoch (Atypical Maker)"
SINCE=2026
YEARS="$SINCE"; [ "$(date +%Y)" != "$SINCE" ] && YEARS="$SINCE–$(date +%Y)"
COPYRIGHT="Copyright © $YEARS $AUTHOR. All rights reserved."
TMP="$(mktemp -d)"
NEW="$TMP/$NAME.app"
trap 'rm -rf "$TMP"' EXIT

echo "› kompiluje"
mkdir -p "$NEW/Contents/MacOS" "$NEW/Contents/Resources"
swiftc -O -swift-version 5 -default-isolation MainActor \
	-target arm64-apple-macos26.0 \
	Sources/*.swift -o "$NEW/Contents/MacOS/$EXEC"

# Wzory rysuje KaTeX z Resources/katex (MIT, licencja obok) - offline, bez CDN.
echo "› KaTeX i szablon karty"
cp Resources/card.html "$NEW/Contents/Resources/"
ditto Resources/katex "$NEW/Contents/Resources/katex"

# Ikona z Icon Composera (Flashcards.icon): system sam kladzie szklo i style ikon.
# actool pamieta ikone po sciezce, wiec kompiluje kopie z jednorazowego katalogu.
echo "› ikona"
cp -R Flashcards.icon "$TMP/Flashcards.icon"
xcrun actool "$TMP/Flashcards.icon" --compile "$NEW/Contents/Resources" \
	--platform macosx --minimum-deployment-target 26.0 --app-icon Flashcards \
	--output-partial-info-plist "$TMP/ikona.plist" >/dev/null

# Nazwa bazowa musi zgadzac sie z nazwa pakietu na dysku, inaczej Finder pokazuje sama
# nazwe pliku zamiast tlumaczenia. Typy dokumentow: CSV, TSV i zwykly tekst, zeby pliki
# otwieraly sie z Findera (Otworz za pomoca) i po upuszczeniu na ikone w Docku.
echo "› Info.plist"
cat > "$NEW/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>$NAME</string>
	<key>CFBundleDisplayName</key><string>$NAME</string>
	<key>LSHasLocalizedDisplayName</key><true/>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleExecutable</key><string>$EXEC</string>
	<key>CFBundleIconFile</key><string>Flashcards</string>
	<key>CFBundleIconName</key><string>Flashcards</string>
	<key>CFBundleIdentifier</key><string>$ID</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.1.1</string>
	<key>CFBundleVersion</key><string>3</string>
	<key>LSMinimumSystemVersion</key><string>26.0</string>
	<key>LSApplicationCategoryType</key><string>public.app-category.education</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSHumanReadableCopyright</key><string>$COPYRIGHT</string>
	<key>CFBundleDocumentTypes</key>
	<array>
		<dict>
			<key>CFBundleTypeRole</key><string>Viewer</string>
			<key>LSHandlerRank</key><string>Alternate</string>
			<key>LSItemContentTypes</key>
			<array>
				<string>public.comma-separated-values-text</string>
				<string>public.tab-separated-values-text</string>
				<string>public.plain-text</string>
			</array>
		</dict>
	</array>
</dict>
</plist>
PLIST

# Nazwa w kazdym z 43 jezykow interfejsu (te same kody co w Sources/Strings.swift).
# Linia praw autorskich z O programie Photo Booth, z autorem w miejscu "Apple Inc.".
echo "› nazwa i prawa autorskie w jezyku systemu"
BOOTH="/System/Applications/Photo Booth.app/Contents/Resources/InfoPlist.loctable"
while IFS='|' read -r L T; do
	[ -z "$L" ] && continue
	mkdir -p "$NEW/Contents/Resources/$L.lproj"
	case "$L" in zh-Hans) B=zh_CN;; zh-Hant) B=zh_TW;; nb) B=no;; pt) B=pt_PT;; *) B="$L";; esac
	C="$(plutil -extract "$B.NSHumanReadableCopyright" raw -o - "$BOOTH" 2>/dev/null)" || C="$COPYRIGHT"
	# Apple pisze tu rozne spacje i znaki kierunku tekstu (he) - perl lapie je wszystkie.
	C="$(printf '%s' "$C" | YEARS="$YEARS" AUTHOR="$AUTHOR" perl -CSDA -pe \
		's/\d{4}(?:\x{2013}\d{4})?([\s\x{200F}\x{2068}]*)Apple[\s\x{00A0}]Inc\./$ENV{YEARS}$1$ENV{AUTHOR}./; s/\.(\x{2069})\./$1./')"
	C="${C//\"/\\\"}"
	printf '"CFBundleName" = "%s";\n"CFBundleDisplayName" = "%s";\n"NSHumanReadableCopyright" = "%s";\n' \
		"$T" "$T" "$C" > "$NEW/Contents/Resources/$L.lproj/InfoPlist.strings"
done <<'NAMES'
en|Flashcards from File
pl|Fiszki z pliku
de|Karteikarten aus Datei
fr|Fiches depuis un fichier
es|Tarjetas desde archivo
pt|Cartões do ficheiro
it|Flashcard da file
nl|Flashcards uit bestand
sv|Studiekort från fil
da|Studiekort fra fil
nb|Studiekort fra fil
fi|Muistikortit tiedostosta
is|Spjöld úr skrá
cs|Kartičky ze souboru
sk|Kartičky zo súboru
sl|Kartice iz datoteke
hr|Kartice iz datoteke
sr|Картице из датотеке
bg|Карти от файл
ro|Fișe din fișier
hu|Szókártyák fájlból
el|Κάρτες από αρχείο
tr|Dosyadan Kartlar
uk|Картки з файлу
ru|Карточки из файла
be|Карткі з файла
lt|Kortelės iš failo
lv|Kartītes no faila
et|Õppekaardid failist
ca|Targetes des d’un fitxer
ar|بطاقات من ملف
he|כרטיסיות מקובץ
fa|کارت‌ها از فایل
hi|फ़ाइल से फ़्लैशकार्ड
bn|ফাইল থেকে ফ্ল্যাশকার্ড
th|แฟลชการ์ดจากไฟล์
vi|Thẻ ghi nhớ từ tệp
id|Kartu Hafalan dari File
ms|Kad Imbas daripada Fail
zh-Hans|文件抽认卡
zh-Hant|檔案字卡
ja|ファイルの単語カード
ko|파일 플래시카드
NAMES
echo "  $(ls -d "$NEW"/Contents/Resources/*.lproj | wc -l | tr -d ' ') jezykow"

echo "› podpisuje ad-hoc"
codesign --force --sign - "$NEW"

# paczka do pobrania: rozpakowac i przeciagnac aplikacje do Aplikacji
echo "› $ZIP"
rm -f "$ZIP"
ditto -c -k --keepParent "$NEW" "$ZIP"

if pgrep -f "$APP/Contents/MacOS/$EXEC" >/dev/null; then
	echo "› zamykam dzialajaca aplikacje"
	osascript -e "if application id \"$ID\" is running then tell application id \"$ID\" to quit" 2>/dev/null || true
	sleep 1
fi

echo "› instaluje w /Applications"
rm -rf "$APP"
ditto "$NEW" "$APP"
# odswiez pamiec podreczna ikon i nazw, inaczej Finder pokazuje stare
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" || true
echo "› gotowe: $APP"
