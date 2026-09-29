/// Azure dil kodlarının Türkçe adları (yalnızca arayüzde gösterim için).
const _names = <String, String>{
  'af': 'Afrikaanca',
  'ar': 'Arapça',
  'az': 'Azerice',
  'bg': 'Bulgarca',
  'bn': 'Bengalce',
  'ca': 'Katalanca',
  'cs': 'Çekçe',
  'da': 'Danca',
  'de': 'Almanca',
  'el': 'Yunanca',
  'en': 'İngilizce',
  'es': 'İspanyolca',
  'et': 'Estonca',
  'fa': 'Farsça',
  'fi': 'Fince',
  'fr': 'Fransızca',
  'he': 'İbranice',
  'hi': 'Hintçe',
  'hr': 'Hırvatça',
  'hu': 'Macarca',
  'id': 'Endonezce',
  'it': 'İtalyanca',
  'ja': 'Japonca',
  'ko': 'Korece',
  'lt': 'Litvanca',
  'lv': 'Letonca',
  'ms': 'Malayca',
  'nb': 'Norveççe',
  'nl': 'Felemenkçe',
  'no': 'Norveççe',
  'pl': 'Lehçe',
  'pt': 'Portekizce',
  'ro': 'Romence',
  'ru': 'Rusça',
  'sk': 'Slovakça',
  'sl': 'Slovence',
  'sr': 'Sırpça',
  'sv': 'İsveççe',
  'th': 'Tayca',
  'tr': 'Türkçe',
  'uk': 'Ukraynaca',
  'ur': 'Urduca',
  'vi': 'Vietnamca',
  'zh': 'Çince',
};

/// [code]'un Türkçe adı (`en` → `İngilizce`); bilinmiyorsa `null`.
/// `zh-Hans` gibi bölgeli kodlar ana dile indirgenir.
String? languageDisplayName(String? code) {
  if (code == null || code.isEmpty) return null;
  return _names[code.split('-').first.toLowerCase()];
}

/// Kaynak dil Türkçe mi? (`tr`, `tr-TR`…) — öyleyse çeviri arayüzü gösterilmez.
bool isTurkish(String? code) =>
    code != null && code.split('-').first.toLowerCase() == 'tr';
