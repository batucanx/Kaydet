/// Her iki Kaydet istemcisinin (telefon ve web) hesap için tuttuğu ayarların
/// (etiketler, imzalar, hazır şablonlar, engellenen kullanıcılar) üç yönlü birleştirilmesi.
///
/// Web ile telefon birbirine bağlanmaz; ikisi de IMAP sunucusundaki TEK bir
/// JSON belgesini okuyup yazar (bkz. `settings_document.dart`). Eşitleyen taraf
/// üç görünümü birleştirip sonucu geri yazar:
///   base   — bu istemcinin en son birleştirdiği belge (diğer tarafla ortak ata),
///   local  — bu istemcide şu an olan,
///   remote — sunucudaki en yeni belge.
/// `local`, `base`ten farklıysa değişiklik yereldir; `remote`, `base`ten
/// farklıysa uzaktır. İki taraf FARKLI şeyleri değiştirdiyse ikisi de korunur;
/// aynı alan iki tarafta değiştiyse yerel kazanır (yazılan odur); bir silme,
/// aynı kaydın değiştirilmesine karşı kaybeder.
///
/// KAYNAK: web projesindeki `packages/domain/src/settings/merge.ts`. İki
/// gerçekleme AYNI davranmak ZORUNDADIR; ortak test tablosu
/// `test/fixtures/settings_vectors.json` (web'deki `vectors.json`un kopyası).
///
/// Kayıtlar açık JSON nesneleridir: bir istemci yalnızca SAHİP OLDUĞU alanları
/// yargılar; tanımadığı alanları ne değiştirir ne siler.
library;

typedef SettingsRecord = Map<String, Object?>;
typedef SettingsCollection = Map<String, SettingsRecord>;

class SettingsData {
  const SettingsData({
    this.labels = const {},
    this.signatures = const {},
    this.templates = const {},
    this.blockedSenders = const {},
  });

  final SettingsCollection labels;
  final SettingsCollection signatures;

  /// Hazır şablonlar (`QuickTemplate`): `{title, content, isBuiltIn}`, kimliğiyle anahtarlı.
  final SettingsCollection templates;

  /// Engellenen kullanıcılar: `{email, name}`, küçük harfli adresiyle anahtarlı. İletileri
  /// İstenmeyen klasöründe tutulur.
  final SettingsCollection blockedSenders;

  static const SettingsData empty = SettingsData();

  Map<String, Object?> toJson() => {
    'labels': labels,
    'signatures': signatures,
    'templates': templates,
    'blockedSenders': blockedSenders,
  };

  factory SettingsData.fromJson(Map<String, Object?> json) => SettingsData(
    labels: _collection(json['labels']),
    signatures: _collection(json['signatures']),
    templates: _collection(json['templates']),
    blockedSenders: _collection(json['blockedSenders']),
  );

  static SettingsCollection _collection(Object? raw) {
    if (raw is! Map) return {};
    return {
      for (final entry in raw.entries)
        if (entry.key is String && entry.value is Map)
          entry.key as String: Map<String, Object?>.from(entry.value as Map),
    };
  }
}

class SettingsMergeResult {
  const SettingsMergeResult({
    required this.merged,
    required this.pushNeeded,
    required this.localChanged,
  });

  final SettingsData merged;

  /// Birleşik sonuç sunucudaki belgeden farklı: yeni bir sürüm yazılmalı.
  final bool pushNeeded;

  /// Birleşik sonuç yerelden (yerelin anladığı kadarıyla) farklı: yerele uygula.
  final bool localChanged;
}

bool settingsDeepEqual(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key) || !settingsDeepEqual(a[key], b[key])) {
        return false;
      }
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!settingsDeepEqual(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

bool settingsDataEqual(SettingsData a, SettingsData b) =>
    settingsDeepEqual(a.labels, b.labels) &&
    settingsDeepEqual(a.signatures, b.signatures) &&
    settingsDeepEqual(a.templates, b.templates) &&
    settingsDeepEqual(a.blockedSenders, b.blockedSenders);

/// [local]in [base]ten farklı alanları (base kaydı yoksa hepsini).
Map<String, Object?> _changedFields(SettingsRecord? base, SettingsRecord local) {
  final out = <String, Object?>{};
  for (final entry in local.entries) {
    if (base == null ||
        !base.containsKey(entry.key) ||
        !settingsDeepEqual(entry.value, base[entry.key])) {
      out[entry.key] = entry.value;
    }
  }
  return out;
}

SettingsRecord? _mergeRecord(
  SettingsRecord? base,
  SettingsRecord? local,
  SettingsRecord? remote, {
  required bool hasBase,
}) {
  if (!hasBase) {
    // Bu istemci belgeyle ilk kez karşılaşıyor: hiçbir şey "değişmiş" sayılmaz,
    // sunucunun görünümü kazanır; kendi alanlarımız yalnızca eksikleri doldurur.
    if (local != null && remote != null) return {...local, ...remote};
    return remote ?? local;
  }
  if (local != null && remote != null) {
    if (base == null) return {...local, ...remote};
    return {...remote, ..._changedFields(base, local)};
  }
  if (local != null) {
    if (base == null) return local; // burada eklendi
    // Karşı tarafta silinmiş. Burada yapılan bir değişiklik o silmeye üstün gelir.
    return _changedFields(base, local).isNotEmpty ? local : null;
  }
  if (remote != null) {
    if (base == null) return remote; // orada eklendi
    // Burada silindi. Orada yapılan bir değişiklik bizim silmemize üstün gelir.
    return settingsDeepEqual(base, remote) ? null : remote;
  }
  return null;
}

SettingsCollection _mergeCollection(
  SettingsCollection? base,
  SettingsCollection local,
  SettingsCollection remote,
) {
  final keys = <String>{
    ...local.keys,
    ...remote.keys,
    if (base != null) ...base.keys,
  }.toList()..sort();
  final out = <String, SettingsRecord>{};
  for (final key in keys) {
    final merged = _mergeRecord(
      base?[key],
      local[key],
      remote[key],
      hasBase: base != null,
    );
    if (merged != null) out[key] = merged;
  }
  return out;
}

/// En fazla bir varsayılan imza: burada varsayılan yapılan kalır, yoksa en küçük anahtar.
SettingsCollection _normalizeDefaultSignature(
  SettingsCollection merged,
  SettingsCollection? base,
  SettingsCollection local,
) {
  final defaults = merged.keys
      .where((k) => merged[k]!['isDefault'] == true)
      .toList(); // anahtar sırasıyla
  if (defaults.length <= 1) return merged;
  final madeDefaultHere = defaults
      .where(
        (k) =>
            local[k]?['isDefault'] == true && base?[k]?['isDefault'] != true,
      )
      .toList();
  final keep = madeDefaultHere.length == 1 ? madeDefaultHere.first : defaults.first;
  return {
    for (final entry in merged.entries)
      entry.key: entry.value['isDefault'] == true && entry.key != keep
          ? {...entry.value, 'isDefault': false}
          : entry.value,
  };
}

/// [merged], [local]den (yerelin anahtarları ve her kaydın KENDİ alanları
/// açısından) farklı mı?
bool _differsFromLocal(SettingsCollection merged, SettingsCollection local) {
  if (merged.length != local.length) return true;
  for (final key in merged.keys) {
    final l = local[key];
    if (l == null) return true;
    final m = merged[key]!;
    for (final entry in l.entries) {
      if (!m.containsKey(entry.key) ||
          !settingsDeepEqual(entry.value, m[entry.key])) {
        return true;
      }
    }
  }
  return false;
}

SettingsMergeResult mergeSettings({
  required SettingsData? base,
  required SettingsData local,
  required SettingsData? remote,
}) {
  // Sunucuda belge yok (hiç yazılmadı ya da klasör kayboldu): bunu asla
  // "her şey silindi" diye okuma.
  final effectiveBase = remote == null ? null : base;
  final remoteData = remote ?? SettingsData.empty;

  final labels = _mergeCollection(
    effectiveBase?.labels,
    local.labels,
    remoteData.labels,
  );
  final signatures = _normalizeDefaultSignature(
    _mergeCollection(
      effectiveBase?.signatures,
      local.signatures,
      remoteData.signatures,
    ),
    effectiveBase?.signatures,
    local.signatures,
  );
  final templates = _mergeCollection(
    effectiveBase?.templates,
    local.templates,
    remoteData.templates,
  );
  final blockedSenders = _mergeCollection(
    effectiveBase?.blockedSenders,
    local.blockedSenders,
    remoteData.blockedSenders,
  );
  final merged = SettingsData(
    labels: labels,
    signatures: signatures,
    templates: templates,
    blockedSenders: blockedSenders,
  );

  final hasAny =
      labels.isNotEmpty ||
      signatures.isNotEmpty ||
      templates.isNotEmpty ||
      blockedSenders.isNotEmpty;
  final pushNeeded = remote == null
      ? hasAny
      : !settingsDataEqual(merged, remote);
  final localChanged =
      _differsFromLocal(labels, local.labels) ||
      _differsFromLocal(signatures, local.signatures) ||
      _differsFromLocal(templates, local.templates) ||
      _differsFromLocal(blockedSenders, local.blockedSenders);
  return SettingsMergeResult(
    merged: merged,
    pushNeeded: pushNeeded,
    localChanged: localChanged,
  );
}
