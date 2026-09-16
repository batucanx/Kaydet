// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_database.dart';

// ignore_for_file: type=lint
class $AccountsTable extends Accounts
    with TableInfo<$AccountsTable, AccountRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AccountsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _emailMeta = const VerificationMeta('email');
  @override
  late final GeneratedColumn<String> email = GeneratedColumn<String>(
    'email',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _displayNameMeta = const VerificationMeta(
    'displayName',
  );
  @override
  late final GeneratedColumn<String> displayName = GeneratedColumn<String>(
    'display_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _usernameMeta = const VerificationMeta(
    'username',
  );
  @override
  late final GeneratedColumn<String> username = GeneratedColumn<String>(
    'username',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _imapHostMeta = const VerificationMeta(
    'imapHost',
  );
  @override
  late final GeneratedColumn<String> imapHost = GeneratedColumn<String>(
    'imap_host',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _imapPortMeta = const VerificationMeta(
    'imapPort',
  );
  @override
  late final GeneratedColumn<int> imapPort = GeneratedColumn<int>(
    'imap_port',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(993),
  );
  @override
  late final GeneratedColumnWithTypeConverter<SocketSecurity, int>
  imapSecurity = GeneratedColumn<int>(
    'imap_security',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(2),
  ).withConverter<SocketSecurity>($AccountsTable.$converterimapSecurity);
  static const VerificationMeta _smtpHostMeta = const VerificationMeta(
    'smtpHost',
  );
  @override
  late final GeneratedColumn<String> smtpHost = GeneratedColumn<String>(
    'smtp_host',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _smtpPortMeta = const VerificationMeta(
    'smtpPort',
  );
  @override
  late final GeneratedColumn<int> smtpPort = GeneratedColumn<int>(
    'smtp_port',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(465),
  );
  @override
  late final GeneratedColumnWithTypeConverter<SocketSecurity, int>
  smtpSecurity = GeneratedColumn<int>(
    'smtp_security',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(2),
  ).withConverter<SocketSecurity>($AccountsTable.$convertersmtpSecurity);
  static const VerificationMeta _signatureMeta = const VerificationMeta(
    'signature',
  );
  @override
  late final GeneratedColumn<String> signature = GeneratedColumn<String>(
    'signature',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _colorSeedMeta = const VerificationMeta(
    'colorSeed',
  );
  @override
  late final GeneratedColumn<int> colorSeed = GeneratedColumn<int>(
    'color_seed',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _isActiveMeta = const VerificationMeta(
    'isActive',
  );
  @override
  late final GeneratedColumn<bool> isActive = GeneratedColumn<bool>(
    'is_active',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_active" IN (0, 1))',
    ),
    defaultValue: const Constant(true),
  );
  @override
  late final GeneratedColumnWithTypeConverter<AuthMethod, int> authMethod =
      GeneratedColumn<int>(
        'auth_method',
        aliasedName,
        false,
        type: DriftSqlType.int,
        requiredDuringInsert: false,
        defaultValue: const Constant(0),
      ).withConverter<AuthMethod>($AccountsTable.$converterauthMethod);
  static const VerificationMeta _supportsKeywordsMeta = const VerificationMeta(
    'supportsKeywords',
  );
  @override
  late final GeneratedColumn<bool> supportsKeywords = GeneratedColumn<bool>(
    'supports_keywords',
    aliasedName,
    true,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("supports_keywords" IN (0, 1))',
    ),
  );
  static const VerificationMeta _capabilitiesJsonMeta = const VerificationMeta(
    'capabilitiesJson',
  );
  @override
  late final GeneratedColumn<String> capabilitiesJson = GeneratedColumn<String>(
    'capabilities_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('[]'),
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
    defaultValue: currentDateAndTime,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    email,
    displayName,
    username,
    imapHost,
    imapPort,
    imapSecurity,
    smtpHost,
    smtpPort,
    smtpSecurity,
    signature,
    colorSeed,
    isActive,
    authMethod,
    supportsKeywords,
    capabilitiesJson,
    createdAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'accounts';
  @override
  VerificationContext validateIntegrity(
    Insertable<AccountRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('email')) {
      context.handle(
        _emailMeta,
        email.isAcceptableOrUnknown(data['email']!, _emailMeta),
      );
    } else if (isInserting) {
      context.missing(_emailMeta);
    }
    if (data.containsKey('display_name')) {
      context.handle(
        _displayNameMeta,
        displayName.isAcceptableOrUnknown(
          data['display_name']!,
          _displayNameMeta,
        ),
      );
    }
    if (data.containsKey('username')) {
      context.handle(
        _usernameMeta,
        username.isAcceptableOrUnknown(data['username']!, _usernameMeta),
      );
    } else if (isInserting) {
      context.missing(_usernameMeta);
    }
    if (data.containsKey('imap_host')) {
      context.handle(
        _imapHostMeta,
        imapHost.isAcceptableOrUnknown(data['imap_host']!, _imapHostMeta),
      );
    } else if (isInserting) {
      context.missing(_imapHostMeta);
    }
    if (data.containsKey('imap_port')) {
      context.handle(
        _imapPortMeta,
        imapPort.isAcceptableOrUnknown(data['imap_port']!, _imapPortMeta),
      );
    }
    if (data.containsKey('smtp_host')) {
      context.handle(
        _smtpHostMeta,
        smtpHost.isAcceptableOrUnknown(data['smtp_host']!, _smtpHostMeta),
      );
    } else if (isInserting) {
      context.missing(_smtpHostMeta);
    }
    if (data.containsKey('smtp_port')) {
      context.handle(
        _smtpPortMeta,
        smtpPort.isAcceptableOrUnknown(data['smtp_port']!, _smtpPortMeta),
      );
    }
    if (data.containsKey('signature')) {
      context.handle(
        _signatureMeta,
        signature.isAcceptableOrUnknown(data['signature']!, _signatureMeta),
      );
    }
    if (data.containsKey('color_seed')) {
      context.handle(
        _colorSeedMeta,
        colorSeed.isAcceptableOrUnknown(data['color_seed']!, _colorSeedMeta),
      );
    }
    if (data.containsKey('is_active')) {
      context.handle(
        _isActiveMeta,
        isActive.isAcceptableOrUnknown(data['is_active']!, _isActiveMeta),
      );
    }
    if (data.containsKey('supports_keywords')) {
      context.handle(
        _supportsKeywordsMeta,
        supportsKeywords.isAcceptableOrUnknown(
          data['supports_keywords']!,
          _supportsKeywordsMeta,
        ),
      );
    }
    if (data.containsKey('capabilities_json')) {
      context.handle(
        _capabilitiesJsonMeta,
        capabilitiesJson.isAcceptableOrUnknown(
          data['capabilities_json']!,
          _capabilitiesJsonMeta,
        ),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  List<Set<GeneratedColumn>> get uniqueKeys => [
    {email},
  ];
  @override
  AccountRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AccountRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      email: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}email'],
      )!,
      displayName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}display_name'],
      )!,
      username: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}username'],
      )!,
      imapHost: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}imap_host'],
      )!,
      imapPort: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}imap_port'],
      )!,
      imapSecurity: $AccountsTable.$converterimapSecurity.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.int,
          data['${effectivePrefix}imap_security'],
        )!,
      ),
      smtpHost: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}smtp_host'],
      )!,
      smtpPort: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}smtp_port'],
      )!,
      smtpSecurity: $AccountsTable.$convertersmtpSecurity.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.int,
          data['${effectivePrefix}smtp_security'],
        )!,
      ),
      signature: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}signature'],
      ),
      colorSeed: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}color_seed'],
      )!,
      isActive: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_active'],
      )!,
      authMethod: $AccountsTable.$converterauthMethod.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.int,
          data['${effectivePrefix}auth_method'],
        )!,
      ),
      supportsKeywords: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}supports_keywords'],
      ),
      capabilitiesJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}capabilities_json'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
    );
  }

  @override
  $AccountsTable createAlias(String alias) {
    return $AccountsTable(attachedDatabase, alias);
  }

  static JsonTypeConverter2<SocketSecurity, int, int> $converterimapSecurity =
      const EnumIndexConverter<SocketSecurity>(SocketSecurity.values);
  static JsonTypeConverter2<SocketSecurity, int, int> $convertersmtpSecurity =
      const EnumIndexConverter<SocketSecurity>(SocketSecurity.values);
  static JsonTypeConverter2<AuthMethod, int, int> $converterauthMethod =
      const EnumIndexConverter<AuthMethod>(AuthMethod.values);
}

class AccountRow extends DataClass implements Insertable<AccountRow> {
  final int id;
  final String email;
  final String displayName;
  final String username;
  final String imapHost;
  final int imapPort;
  final SocketSecurity imapSecurity;
  final String smtpHost;
  final int smtpPort;
  final SocketSecurity smtpSecurity;
  final String? signature;
  final int colorSeed;
  final bool isActive;

  /// Kimlik doğrulama biçimi — `password` (0) veya `googleOAuth` (1).
  /// Gerçek şifre/token değeri burada değil, [SecureStore]'da tutulur.
  final AuthMethod authMethod;

  /// Sunucu özel anahtar kelime (etiket) destekliyor mu? `null` = bilinmiyor.
  final bool? supportsKeywords;
  final String capabilitiesJson;
  final DateTime createdAt;
  const AccountRow({
    required this.id,
    required this.email,
    required this.displayName,
    required this.username,
    required this.imapHost,
    required this.imapPort,
    required this.imapSecurity,
    required this.smtpHost,
    required this.smtpPort,
    required this.smtpSecurity,
    this.signature,
    required this.colorSeed,
    required this.isActive,
    required this.authMethod,
    this.supportsKeywords,
    required this.capabilitiesJson,
    required this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['email'] = Variable<String>(email);
    map['display_name'] = Variable<String>(displayName);
    map['username'] = Variable<String>(username);
    map['imap_host'] = Variable<String>(imapHost);
    map['imap_port'] = Variable<int>(imapPort);
    {
      map['imap_security'] = Variable<int>(
        $AccountsTable.$converterimapSecurity.toSql(imapSecurity),
      );
    }
    map['smtp_host'] = Variable<String>(smtpHost);
    map['smtp_port'] = Variable<int>(smtpPort);
    {
      map['smtp_security'] = Variable<int>(
        $AccountsTable.$convertersmtpSecurity.toSql(smtpSecurity),
      );
    }
    if (!nullToAbsent || signature != null) {
      map['signature'] = Variable<String>(signature);
    }
    map['color_seed'] = Variable<int>(colorSeed);
    map['is_active'] = Variable<bool>(isActive);
    {
      map['auth_method'] = Variable<int>(
        $AccountsTable.$converterauthMethod.toSql(authMethod),
      );
    }
    if (!nullToAbsent || supportsKeywords != null) {
      map['supports_keywords'] = Variable<bool>(supportsKeywords);
    }
    map['capabilities_json'] = Variable<String>(capabilitiesJson);
    map['created_at'] = Variable<DateTime>(createdAt);
    return map;
  }

  AccountsCompanion toCompanion(bool nullToAbsent) {
    return AccountsCompanion(
      id: Value(id),
      email: Value(email),
      displayName: Value(displayName),
      username: Value(username),
      imapHost: Value(imapHost),
      imapPort: Value(imapPort),
      imapSecurity: Value(imapSecurity),
      smtpHost: Value(smtpHost),
      smtpPort: Value(smtpPort),
      smtpSecurity: Value(smtpSecurity),
      signature: signature == null && nullToAbsent
          ? const Value.absent()
          : Value(signature),
      colorSeed: Value(colorSeed),
      isActive: Value(isActive),
      authMethod: Value(authMethod),
      supportsKeywords: supportsKeywords == null && nullToAbsent
          ? const Value.absent()
          : Value(supportsKeywords),
      capabilitiesJson: Value(capabilitiesJson),
      createdAt: Value(createdAt),
    );
  }

  factory AccountRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AccountRow(
      id: serializer.fromJson<int>(json['id']),
      email: serializer.fromJson<String>(json['email']),
      displayName: serializer.fromJson<String>(json['displayName']),
      username: serializer.fromJson<String>(json['username']),
      imapHost: serializer.fromJson<String>(json['imapHost']),
      imapPort: serializer.fromJson<int>(json['imapPort']),
      imapSecurity: $AccountsTable.$converterimapSecurity.fromJson(
        serializer.fromJson<int>(json['imapSecurity']),
      ),
      smtpHost: serializer.fromJson<String>(json['smtpHost']),
      smtpPort: serializer.fromJson<int>(json['smtpPort']),
      smtpSecurity: $AccountsTable.$convertersmtpSecurity.fromJson(
        serializer.fromJson<int>(json['smtpSecurity']),
      ),
      signature: serializer.fromJson<String?>(json['signature']),
      colorSeed: serializer.fromJson<int>(json['colorSeed']),
      isActive: serializer.fromJson<bool>(json['isActive']),
      authMethod: $AccountsTable.$converterauthMethod.fromJson(
        serializer.fromJson<int>(json['authMethod']),
      ),
      supportsKeywords: serializer.fromJson<bool?>(json['supportsKeywords']),
      capabilitiesJson: serializer.fromJson<String>(json['capabilitiesJson']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'email': serializer.toJson<String>(email),
      'displayName': serializer.toJson<String>(displayName),
      'username': serializer.toJson<String>(username),
      'imapHost': serializer.toJson<String>(imapHost),
      'imapPort': serializer.toJson<int>(imapPort),
      'imapSecurity': serializer.toJson<int>(
        $AccountsTable.$converterimapSecurity.toJson(imapSecurity),
      ),
      'smtpHost': serializer.toJson<String>(smtpHost),
      'smtpPort': serializer.toJson<int>(smtpPort),
      'smtpSecurity': serializer.toJson<int>(
        $AccountsTable.$convertersmtpSecurity.toJson(smtpSecurity),
      ),
      'signature': serializer.toJson<String?>(signature),
      'colorSeed': serializer.toJson<int>(colorSeed),
      'isActive': serializer.toJson<bool>(isActive),
      'authMethod': serializer.toJson<int>(
        $AccountsTable.$converterauthMethod.toJson(authMethod),
      ),
      'supportsKeywords': serializer.toJson<bool?>(supportsKeywords),
      'capabilitiesJson': serializer.toJson<String>(capabilitiesJson),
      'createdAt': serializer.toJson<DateTime>(createdAt),
    };
  }

  AccountRow copyWith({
    int? id,
    String? email,
    String? displayName,
    String? username,
    String? imapHost,
    int? imapPort,
    SocketSecurity? imapSecurity,
    String? smtpHost,
    int? smtpPort,
    SocketSecurity? smtpSecurity,
    Value<String?> signature = const Value.absent(),
    int? colorSeed,
    bool? isActive,
    AuthMethod? authMethod,
    Value<bool?> supportsKeywords = const Value.absent(),
    String? capabilitiesJson,
    DateTime? createdAt,
  }) => AccountRow(
    id: id ?? this.id,
    email: email ?? this.email,
    displayName: displayName ?? this.displayName,
    username: username ?? this.username,
    imapHost: imapHost ?? this.imapHost,
    imapPort: imapPort ?? this.imapPort,
    imapSecurity: imapSecurity ?? this.imapSecurity,
    smtpHost: smtpHost ?? this.smtpHost,
    smtpPort: smtpPort ?? this.smtpPort,
    smtpSecurity: smtpSecurity ?? this.smtpSecurity,
    signature: signature.present ? signature.value : this.signature,
    colorSeed: colorSeed ?? this.colorSeed,
    isActive: isActive ?? this.isActive,
    authMethod: authMethod ?? this.authMethod,
    supportsKeywords: supportsKeywords.present
        ? supportsKeywords.value
        : this.supportsKeywords,
    capabilitiesJson: capabilitiesJson ?? this.capabilitiesJson,
    createdAt: createdAt ?? this.createdAt,
  );
  AccountRow copyWithCompanion(AccountsCompanion data) {
    return AccountRow(
      id: data.id.present ? data.id.value : this.id,
      email: data.email.present ? data.email.value : this.email,
      displayName: data.displayName.present
          ? data.displayName.value
          : this.displayName,
      username: data.username.present ? data.username.value : this.username,
      imapHost: data.imapHost.present ? data.imapHost.value : this.imapHost,
      imapPort: data.imapPort.present ? data.imapPort.value : this.imapPort,
      imapSecurity: data.imapSecurity.present
          ? data.imapSecurity.value
          : this.imapSecurity,
      smtpHost: data.smtpHost.present ? data.smtpHost.value : this.smtpHost,
      smtpPort: data.smtpPort.present ? data.smtpPort.value : this.smtpPort,
      smtpSecurity: data.smtpSecurity.present
          ? data.smtpSecurity.value
          : this.smtpSecurity,
      signature: data.signature.present ? data.signature.value : this.signature,
      colorSeed: data.colorSeed.present ? data.colorSeed.value : this.colorSeed,
      isActive: data.isActive.present ? data.isActive.value : this.isActive,
      authMethod: data.authMethod.present
          ? data.authMethod.value
          : this.authMethod,
      supportsKeywords: data.supportsKeywords.present
          ? data.supportsKeywords.value
          : this.supportsKeywords,
      capabilitiesJson: data.capabilitiesJson.present
          ? data.capabilitiesJson.value
          : this.capabilitiesJson,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AccountRow(')
          ..write('id: $id, ')
          ..write('email: $email, ')
          ..write('displayName: $displayName, ')
          ..write('username: $username, ')
          ..write('imapHost: $imapHost, ')
          ..write('imapPort: $imapPort, ')
          ..write('imapSecurity: $imapSecurity, ')
          ..write('smtpHost: $smtpHost, ')
          ..write('smtpPort: $smtpPort, ')
          ..write('smtpSecurity: $smtpSecurity, ')
          ..write('signature: $signature, ')
          ..write('colorSeed: $colorSeed, ')
          ..write('isActive: $isActive, ')
          ..write('authMethod: $authMethod, ')
          ..write('supportsKeywords: $supportsKeywords, ')
          ..write('capabilitiesJson: $capabilitiesJson, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    email,
    displayName,
    username,
    imapHost,
    imapPort,
    imapSecurity,
    smtpHost,
    smtpPort,
    smtpSecurity,
    signature,
    colorSeed,
    isActive,
    authMethod,
    supportsKeywords,
    capabilitiesJson,
    createdAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AccountRow &&
          other.id == this.id &&
          other.email == this.email &&
          other.displayName == this.displayName &&
          other.username == this.username &&
          other.imapHost == this.imapHost &&
          other.imapPort == this.imapPort &&
          other.imapSecurity == this.imapSecurity &&
          other.smtpHost == this.smtpHost &&
          other.smtpPort == this.smtpPort &&
          other.smtpSecurity == this.smtpSecurity &&
          other.signature == this.signature &&
          other.colorSeed == this.colorSeed &&
          other.isActive == this.isActive &&
          other.authMethod == this.authMethod &&
          other.supportsKeywords == this.supportsKeywords &&
          other.capabilitiesJson == this.capabilitiesJson &&
          other.createdAt == this.createdAt);
}

class AccountsCompanion extends UpdateCompanion<AccountRow> {
  final Value<int> id;
  final Value<String> email;
  final Value<String> displayName;
  final Value<String> username;
  final Value<String> imapHost;
  final Value<int> imapPort;
  final Value<SocketSecurity> imapSecurity;
  final Value<String> smtpHost;
  final Value<int> smtpPort;
  final Value<SocketSecurity> smtpSecurity;
  final Value<String?> signature;
  final Value<int> colorSeed;
  final Value<bool> isActive;
  final Value<AuthMethod> authMethod;
  final Value<bool?> supportsKeywords;
  final Value<String> capabilitiesJson;
  final Value<DateTime> createdAt;
  const AccountsCompanion({
    this.id = const Value.absent(),
    this.email = const Value.absent(),
    this.displayName = const Value.absent(),
    this.username = const Value.absent(),
    this.imapHost = const Value.absent(),
    this.imapPort = const Value.absent(),
    this.imapSecurity = const Value.absent(),
    this.smtpHost = const Value.absent(),
    this.smtpPort = const Value.absent(),
    this.smtpSecurity = const Value.absent(),
    this.signature = const Value.absent(),
    this.colorSeed = const Value.absent(),
    this.isActive = const Value.absent(),
    this.authMethod = const Value.absent(),
    this.supportsKeywords = const Value.absent(),
    this.capabilitiesJson = const Value.absent(),
    this.createdAt = const Value.absent(),
  });
  AccountsCompanion.insert({
    this.id = const Value.absent(),
    required String email,
    this.displayName = const Value.absent(),
    required String username,
    required String imapHost,
    this.imapPort = const Value.absent(),
    this.imapSecurity = const Value.absent(),
    required String smtpHost,
    this.smtpPort = const Value.absent(),
    this.smtpSecurity = const Value.absent(),
    this.signature = const Value.absent(),
    this.colorSeed = const Value.absent(),
    this.isActive = const Value.absent(),
    this.authMethod = const Value.absent(),
    this.supportsKeywords = const Value.absent(),
    this.capabilitiesJson = const Value.absent(),
    this.createdAt = const Value.absent(),
  }) : email = Value(email),
       username = Value(username),
       imapHost = Value(imapHost),
       smtpHost = Value(smtpHost);
  static Insertable<AccountRow> custom({
    Expression<int>? id,
    Expression<String>? email,
    Expression<String>? displayName,
    Expression<String>? username,
    Expression<String>? imapHost,
    Expression<int>? imapPort,
    Expression<int>? imapSecurity,
    Expression<String>? smtpHost,
    Expression<int>? smtpPort,
    Expression<int>? smtpSecurity,
    Expression<String>? signature,
    Expression<int>? colorSeed,
    Expression<bool>? isActive,
    Expression<int>? authMethod,
    Expression<bool>? supportsKeywords,
    Expression<String>? capabilitiesJson,
    Expression<DateTime>? createdAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (email != null) 'email': email,
      if (displayName != null) 'display_name': displayName,
      if (username != null) 'username': username,
      if (imapHost != null) 'imap_host': imapHost,
      if (imapPort != null) 'imap_port': imapPort,
      if (imapSecurity != null) 'imap_security': imapSecurity,
      if (smtpHost != null) 'smtp_host': smtpHost,
      if (smtpPort != null) 'smtp_port': smtpPort,
      if (smtpSecurity != null) 'smtp_security': smtpSecurity,
      if (signature != null) 'signature': signature,
      if (colorSeed != null) 'color_seed': colorSeed,
      if (isActive != null) 'is_active': isActive,
      if (authMethod != null) 'auth_method': authMethod,
      if (supportsKeywords != null) 'supports_keywords': supportsKeywords,
      if (capabilitiesJson != null) 'capabilities_json': capabilitiesJson,
      if (createdAt != null) 'created_at': createdAt,
    });
  }

  AccountsCompanion copyWith({
    Value<int>? id,
    Value<String>? email,
    Value<String>? displayName,
    Value<String>? username,
    Value<String>? imapHost,
    Value<int>? imapPort,
    Value<SocketSecurity>? imapSecurity,
    Value<String>? smtpHost,
    Value<int>? smtpPort,
    Value<SocketSecurity>? smtpSecurity,
    Value<String?>? signature,
    Value<int>? colorSeed,
    Value<bool>? isActive,
    Value<AuthMethod>? authMethod,
    Value<bool?>? supportsKeywords,
    Value<String>? capabilitiesJson,
    Value<DateTime>? createdAt,
  }) {
    return AccountsCompanion(
      id: id ?? this.id,
      email: email ?? this.email,
      displayName: displayName ?? this.displayName,
      username: username ?? this.username,
      imapHost: imapHost ?? this.imapHost,
      imapPort: imapPort ?? this.imapPort,
      imapSecurity: imapSecurity ?? this.imapSecurity,
      smtpHost: smtpHost ?? this.smtpHost,
      smtpPort: smtpPort ?? this.smtpPort,
      smtpSecurity: smtpSecurity ?? this.smtpSecurity,
      signature: signature ?? this.signature,
      colorSeed: colorSeed ?? this.colorSeed,
      isActive: isActive ?? this.isActive,
      authMethod: authMethod ?? this.authMethod,
      supportsKeywords: supportsKeywords ?? this.supportsKeywords,
      capabilitiesJson: capabilitiesJson ?? this.capabilitiesJson,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (email.present) {
      map['email'] = Variable<String>(email.value);
    }
    if (displayName.present) {
      map['display_name'] = Variable<String>(displayName.value);
    }
    if (username.present) {
      map['username'] = Variable<String>(username.value);
    }
    if (imapHost.present) {
      map['imap_host'] = Variable<String>(imapHost.value);
    }
    if (imapPort.present) {
      map['imap_port'] = Variable<int>(imapPort.value);
    }
    if (imapSecurity.present) {
      map['imap_security'] = Variable<int>(
        $AccountsTable.$converterimapSecurity.toSql(imapSecurity.value),
      );
    }
    if (smtpHost.present) {
      map['smtp_host'] = Variable<String>(smtpHost.value);
    }
    if (smtpPort.present) {
      map['smtp_port'] = Variable<int>(smtpPort.value);
    }
    if (smtpSecurity.present) {
      map['smtp_security'] = Variable<int>(
        $AccountsTable.$convertersmtpSecurity.toSql(smtpSecurity.value),
      );
    }
    if (signature.present) {
      map['signature'] = Variable<String>(signature.value);
    }
    if (colorSeed.present) {
      map['color_seed'] = Variable<int>(colorSeed.value);
    }
    if (isActive.present) {
      map['is_active'] = Variable<bool>(isActive.value);
    }
    if (authMethod.present) {
      map['auth_method'] = Variable<int>(
        $AccountsTable.$converterauthMethod.toSql(authMethod.value),
      );
    }
    if (supportsKeywords.present) {
      map['supports_keywords'] = Variable<bool>(supportsKeywords.value);
    }
    if (capabilitiesJson.present) {
      map['capabilities_json'] = Variable<String>(capabilitiesJson.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AccountsCompanion(')
          ..write('id: $id, ')
          ..write('email: $email, ')
          ..write('displayName: $displayName, ')
          ..write('username: $username, ')
          ..write('imapHost: $imapHost, ')
          ..write('imapPort: $imapPort, ')
          ..write('imapSecurity: $imapSecurity, ')
          ..write('smtpHost: $smtpHost, ')
          ..write('smtpPort: $smtpPort, ')
          ..write('smtpSecurity: $smtpSecurity, ')
          ..write('signature: $signature, ')
          ..write('colorSeed: $colorSeed, ')
          ..write('isActive: $isActive, ')
          ..write('authMethod: $authMethod, ')
          ..write('supportsKeywords: $supportsKeywords, ')
          ..write('capabilitiesJson: $capabilitiesJson, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }
}

class $MailboxesTable extends Mailboxes
    with TableInfo<$MailboxesTable, MailboxRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MailboxesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _accountIdMeta = const VerificationMeta(
    'accountId',
  );
  @override
  late final GeneratedColumn<int> accountId = GeneratedColumn<int>(
    'account_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES accounts (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _pathMeta = const VerificationMeta('path');
  @override
  late final GeneratedColumn<String> path = GeneratedColumn<String>(
    'path',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _encodedPathMeta = const VerificationMeta(
    'encodedPath',
  );
  @override
  late final GeneratedColumn<String> encodedPath = GeneratedColumn<String>(
    'encoded_path',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  late final GeneratedColumnWithTypeConverter<SpecialUse, int> specialUse =
      GeneratedColumn<int>(
        'special_use',
        aliasedName,
        false,
        type: DriftSqlType.int,
        requiredDuringInsert: false,
        defaultValue: const Constant(6),
      ).withConverter<SpecialUse>($MailboxesTable.$converterspecialUse);
  static const VerificationMeta _delimiterMeta = const VerificationMeta(
    'delimiter',
  );
  @override
  late final GeneratedColumn<String> delimiter = GeneratedColumn<String>(
    'delimiter',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('.'),
  );
  static const VerificationMeta _uidValidityMeta = const VerificationMeta(
    'uidValidity',
  );
  @override
  late final GeneratedColumn<int> uidValidity = GeneratedColumn<int>(
    'uid_validity',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _uidNextMeta = const VerificationMeta(
    'uidNext',
  );
  @override
  late final GeneratedColumn<int> uidNext = GeneratedColumn<int>(
    'uid_next',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _highestModSeqMeta = const VerificationMeta(
    'highestModSeq',
  );
  @override
  late final GeneratedColumn<int> highestModSeq = GeneratedColumn<int>(
    'highest_mod_seq',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _totalCountMeta = const VerificationMeta(
    'totalCount',
  );
  @override
  late final GeneratedColumn<int> totalCount = GeneratedColumn<int>(
    'total_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _unreadCountMeta = const VerificationMeta(
    'unreadCount',
  );
  @override
  late final GeneratedColumn<int> unreadCount = GeneratedColumn<int>(
    'unread_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _isSubscribedMeta = const VerificationMeta(
    'isSubscribed',
  );
  @override
  late final GeneratedColumn<bool> isSubscribed = GeneratedColumn<bool>(
    'is_subscribed',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_subscribed" IN (0, 1))',
    ),
    defaultValue: const Constant(true),
  );
  static const VerificationMeta _isSelectableMeta = const VerificationMeta(
    'isSelectable',
  );
  @override
  late final GeneratedColumn<bool> isSelectable = GeneratedColumn<bool>(
    'is_selectable',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_selectable" IN (0, 1))',
    ),
    defaultValue: const Constant(true),
  );
  static const VerificationMeta _lastSyncAtMeta = const VerificationMeta(
    'lastSyncAt',
  );
  @override
  late final GeneratedColumn<DateTime> lastSyncAt = GeneratedColumn<DateTime>(
    'last_sync_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _sortOrderMeta = const VerificationMeta(
    'sortOrder',
  );
  @override
  late final GeneratedColumn<int> sortOrder = GeneratedColumn<int>(
    'sort_order',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(100),
  );
  static const VerificationMeta _hasMoreOnServerMeta = const VerificationMeta(
    'hasMoreOnServer',
  );
  @override
  late final GeneratedColumn<bool> hasMoreOnServer = GeneratedColumn<bool>(
    'has_more_on_server',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("has_more_on_server" IN (0, 1))',
    ),
    defaultValue: const Constant(true),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    accountId,
    path,
    encodedPath,
    name,
    specialUse,
    delimiter,
    uidValidity,
    uidNext,
    highestModSeq,
    totalCount,
    unreadCount,
    isSubscribed,
    isSelectable,
    lastSyncAt,
    sortOrder,
    hasMoreOnServer,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'mailboxes';
  @override
  VerificationContext validateIntegrity(
    Insertable<MailboxRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('account_id')) {
      context.handle(
        _accountIdMeta,
        accountId.isAcceptableOrUnknown(data['account_id']!, _accountIdMeta),
      );
    } else if (isInserting) {
      context.missing(_accountIdMeta);
    }
    if (data.containsKey('path')) {
      context.handle(
        _pathMeta,
        path.isAcceptableOrUnknown(data['path']!, _pathMeta),
      );
    } else if (isInserting) {
      context.missing(_pathMeta);
    }
    if (data.containsKey('encoded_path')) {
      context.handle(
        _encodedPathMeta,
        encodedPath.isAcceptableOrUnknown(
          data['encoded_path']!,
          _encodedPathMeta,
        ),
      );
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('delimiter')) {
      context.handle(
        _delimiterMeta,
        delimiter.isAcceptableOrUnknown(data['delimiter']!, _delimiterMeta),
      );
    }
    if (data.containsKey('uid_validity')) {
      context.handle(
        _uidValidityMeta,
        uidValidity.isAcceptableOrUnknown(
          data['uid_validity']!,
          _uidValidityMeta,
        ),
      );
    }
    if (data.containsKey('uid_next')) {
      context.handle(
        _uidNextMeta,
        uidNext.isAcceptableOrUnknown(data['uid_next']!, _uidNextMeta),
      );
    }
    if (data.containsKey('highest_mod_seq')) {
      context.handle(
        _highestModSeqMeta,
        highestModSeq.isAcceptableOrUnknown(
          data['highest_mod_seq']!,
          _highestModSeqMeta,
        ),
      );
    }
    if (data.containsKey('total_count')) {
      context.handle(
        _totalCountMeta,
        totalCount.isAcceptableOrUnknown(data['total_count']!, _totalCountMeta),
      );
    }
    if (data.containsKey('unread_count')) {
      context.handle(
        _unreadCountMeta,
        unreadCount.isAcceptableOrUnknown(
          data['unread_count']!,
          _unreadCountMeta,
        ),
      );
    }
    if (data.containsKey('is_subscribed')) {
      context.handle(
        _isSubscribedMeta,
        isSubscribed.isAcceptableOrUnknown(
          data['is_subscribed']!,
          _isSubscribedMeta,
        ),
      );
    }
    if (data.containsKey('is_selectable')) {
      context.handle(
        _isSelectableMeta,
        isSelectable.isAcceptableOrUnknown(
          data['is_selectable']!,
          _isSelectableMeta,
        ),
      );
    }
    if (data.containsKey('last_sync_at')) {
      context.handle(
        _lastSyncAtMeta,
        lastSyncAt.isAcceptableOrUnknown(
          data['last_sync_at']!,
          _lastSyncAtMeta,
        ),
      );
    }
    if (data.containsKey('sort_order')) {
      context.handle(
        _sortOrderMeta,
        sortOrder.isAcceptableOrUnknown(data['sort_order']!, _sortOrderMeta),
      );
    }
    if (data.containsKey('has_more_on_server')) {
      context.handle(
        _hasMoreOnServerMeta,
        hasMoreOnServer.isAcceptableOrUnknown(
          data['has_more_on_server']!,
          _hasMoreOnServerMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  List<Set<GeneratedColumn>> get uniqueKeys => [
    {accountId, path},
  ];
  @override
  MailboxRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MailboxRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}account_id'],
      )!,
      path: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}path'],
      )!,
      encodedPath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}encoded_path'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      specialUse: $MailboxesTable.$converterspecialUse.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.int,
          data['${effectivePrefix}special_use'],
        )!,
      ),
      delimiter: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}delimiter'],
      )!,
      uidValidity: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}uid_validity'],
      ),
      uidNext: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}uid_next'],
      ),
      highestModSeq: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}highest_mod_seq'],
      ),
      totalCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}total_count'],
      )!,
      unreadCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}unread_count'],
      )!,
      isSubscribed: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_subscribed'],
      )!,
      isSelectable: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_selectable'],
      )!,
      lastSyncAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}last_sync_at'],
      ),
      sortOrder: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sort_order'],
      )!,
      hasMoreOnServer: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}has_more_on_server'],
      )!,
    );
  }

  @override
  $MailboxesTable createAlias(String alias) {
    return $MailboxesTable(attachedDatabase, alias);
  }

  static JsonTypeConverter2<SpecialUse, int, int> $converterspecialUse =
      const EnumIndexConverter<SpecialUse>(SpecialUse.values);
}

class MailboxRow extends DataClass implements Insertable<MailboxRow> {
  final int id;
  final int accountId;
  final String path;
  final String encodedPath;
  final String name;
  final SpecialUse specialUse;
  final String delimiter;

  /// IMAP UIDVALIDITY — değişirse yerel önbellek geçersizdir.
  final int? uidValidity;
  final int? uidNext;
  final int? highestModSeq;
  final int totalCount;
  final int unreadCount;
  final bool isSubscribed;
  final bool isSelectable;
  final DateTime? lastSyncAt;
  final int sortOrder;

  /// Sunucuda daha eski ileti kaldı mı? (sayfalama sonu göstergesi)
  final bool hasMoreOnServer;
  const MailboxRow({
    required this.id,
    required this.accountId,
    required this.path,
    required this.encodedPath,
    required this.name,
    required this.specialUse,
    required this.delimiter,
    this.uidValidity,
    this.uidNext,
    this.highestModSeq,
    required this.totalCount,
    required this.unreadCount,
    required this.isSubscribed,
    required this.isSelectable,
    this.lastSyncAt,
    required this.sortOrder,
    required this.hasMoreOnServer,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['account_id'] = Variable<int>(accountId);
    map['path'] = Variable<String>(path);
    map['encoded_path'] = Variable<String>(encodedPath);
    map['name'] = Variable<String>(name);
    {
      map['special_use'] = Variable<int>(
        $MailboxesTable.$converterspecialUse.toSql(specialUse),
      );
    }
    map['delimiter'] = Variable<String>(delimiter);
    if (!nullToAbsent || uidValidity != null) {
      map['uid_validity'] = Variable<int>(uidValidity);
    }
    if (!nullToAbsent || uidNext != null) {
      map['uid_next'] = Variable<int>(uidNext);
    }
    if (!nullToAbsent || highestModSeq != null) {
      map['highest_mod_seq'] = Variable<int>(highestModSeq);
    }
    map['total_count'] = Variable<int>(totalCount);
    map['unread_count'] = Variable<int>(unreadCount);
    map['is_subscribed'] = Variable<bool>(isSubscribed);
    map['is_selectable'] = Variable<bool>(isSelectable);
    if (!nullToAbsent || lastSyncAt != null) {
      map['last_sync_at'] = Variable<DateTime>(lastSyncAt);
    }
    map['sort_order'] = Variable<int>(sortOrder);
    map['has_more_on_server'] = Variable<bool>(hasMoreOnServer);
    return map;
  }

  MailboxesCompanion toCompanion(bool nullToAbsent) {
    return MailboxesCompanion(
      id: Value(id),
      accountId: Value(accountId),
      path: Value(path),
      encodedPath: Value(encodedPath),
      name: Value(name),
      specialUse: Value(specialUse),
      delimiter: Value(delimiter),
      uidValidity: uidValidity == null && nullToAbsent
          ? const Value.absent()
          : Value(uidValidity),
      uidNext: uidNext == null && nullToAbsent
          ? const Value.absent()
          : Value(uidNext),
      highestModSeq: highestModSeq == null && nullToAbsent
          ? const Value.absent()
          : Value(highestModSeq),
      totalCount: Value(totalCount),
      unreadCount: Value(unreadCount),
      isSubscribed: Value(isSubscribed),
      isSelectable: Value(isSelectable),
      lastSyncAt: lastSyncAt == null && nullToAbsent
          ? const Value.absent()
          : Value(lastSyncAt),
      sortOrder: Value(sortOrder),
      hasMoreOnServer: Value(hasMoreOnServer),
    );
  }

  factory MailboxRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MailboxRow(
      id: serializer.fromJson<int>(json['id']),
      accountId: serializer.fromJson<int>(json['accountId']),
      path: serializer.fromJson<String>(json['path']),
      encodedPath: serializer.fromJson<String>(json['encodedPath']),
      name: serializer.fromJson<String>(json['name']),
      specialUse: $MailboxesTable.$converterspecialUse.fromJson(
        serializer.fromJson<int>(json['specialUse']),
      ),
      delimiter: serializer.fromJson<String>(json['delimiter']),
      uidValidity: serializer.fromJson<int?>(json['uidValidity']),
      uidNext: serializer.fromJson<int?>(json['uidNext']),
      highestModSeq: serializer.fromJson<int?>(json['highestModSeq']),
      totalCount: serializer.fromJson<int>(json['totalCount']),
      unreadCount: serializer.fromJson<int>(json['unreadCount']),
      isSubscribed: serializer.fromJson<bool>(json['isSubscribed']),
      isSelectable: serializer.fromJson<bool>(json['isSelectable']),
      lastSyncAt: serializer.fromJson<DateTime?>(json['lastSyncAt']),
      sortOrder: serializer.fromJson<int>(json['sortOrder']),
      hasMoreOnServer: serializer.fromJson<bool>(json['hasMoreOnServer']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'accountId': serializer.toJson<int>(accountId),
      'path': serializer.toJson<String>(path),
      'encodedPath': serializer.toJson<String>(encodedPath),
      'name': serializer.toJson<String>(name),
      'specialUse': serializer.toJson<int>(
        $MailboxesTable.$converterspecialUse.toJson(specialUse),
      ),
      'delimiter': serializer.toJson<String>(delimiter),
      'uidValidity': serializer.toJson<int?>(uidValidity),
      'uidNext': serializer.toJson<int?>(uidNext),
      'highestModSeq': serializer.toJson<int?>(highestModSeq),
      'totalCount': serializer.toJson<int>(totalCount),
      'unreadCount': serializer.toJson<int>(unreadCount),
      'isSubscribed': serializer.toJson<bool>(isSubscribed),
      'isSelectable': serializer.toJson<bool>(isSelectable),
      'lastSyncAt': serializer.toJson<DateTime?>(lastSyncAt),
      'sortOrder': serializer.toJson<int>(sortOrder),
      'hasMoreOnServer': serializer.toJson<bool>(hasMoreOnServer),
    };
  }

  MailboxRow copyWith({
    int? id,
    int? accountId,
    String? path,
    String? encodedPath,
    String? name,
    SpecialUse? specialUse,
    String? delimiter,
    Value<int?> uidValidity = const Value.absent(),
    Value<int?> uidNext = const Value.absent(),
    Value<int?> highestModSeq = const Value.absent(),
    int? totalCount,
    int? unreadCount,
    bool? isSubscribed,
    bool? isSelectable,
    Value<DateTime?> lastSyncAt = const Value.absent(),
    int? sortOrder,
    bool? hasMoreOnServer,
  }) => MailboxRow(
    id: id ?? this.id,
    accountId: accountId ?? this.accountId,
    path: path ?? this.path,
    encodedPath: encodedPath ?? this.encodedPath,
    name: name ?? this.name,
    specialUse: specialUse ?? this.specialUse,
    delimiter: delimiter ?? this.delimiter,
    uidValidity: uidValidity.present ? uidValidity.value : this.uidValidity,
    uidNext: uidNext.present ? uidNext.value : this.uidNext,
    highestModSeq: highestModSeq.present
        ? highestModSeq.value
        : this.highestModSeq,
    totalCount: totalCount ?? this.totalCount,
    unreadCount: unreadCount ?? this.unreadCount,
    isSubscribed: isSubscribed ?? this.isSubscribed,
    isSelectable: isSelectable ?? this.isSelectable,
    lastSyncAt: lastSyncAt.present ? lastSyncAt.value : this.lastSyncAt,
    sortOrder: sortOrder ?? this.sortOrder,
    hasMoreOnServer: hasMoreOnServer ?? this.hasMoreOnServer,
  );
  MailboxRow copyWithCompanion(MailboxesCompanion data) {
    return MailboxRow(
      id: data.id.present ? data.id.value : this.id,
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      path: data.path.present ? data.path.value : this.path,
      encodedPath: data.encodedPath.present
          ? data.encodedPath.value
          : this.encodedPath,
      name: data.name.present ? data.name.value : this.name,
      specialUse: data.specialUse.present
          ? data.specialUse.value
          : this.specialUse,
      delimiter: data.delimiter.present ? data.delimiter.value : this.delimiter,
      uidValidity: data.uidValidity.present
          ? data.uidValidity.value
          : this.uidValidity,
      uidNext: data.uidNext.present ? data.uidNext.value : this.uidNext,
      highestModSeq: data.highestModSeq.present
          ? data.highestModSeq.value
          : this.highestModSeq,
      totalCount: data.totalCount.present
          ? data.totalCount.value
          : this.totalCount,
      unreadCount: data.unreadCount.present
          ? data.unreadCount.value
          : this.unreadCount,
      isSubscribed: data.isSubscribed.present
          ? data.isSubscribed.value
          : this.isSubscribed,
      isSelectable: data.isSelectable.present
          ? data.isSelectable.value
          : this.isSelectable,
      lastSyncAt: data.lastSyncAt.present
          ? data.lastSyncAt.value
          : this.lastSyncAt,
      sortOrder: data.sortOrder.present ? data.sortOrder.value : this.sortOrder,
      hasMoreOnServer: data.hasMoreOnServer.present
          ? data.hasMoreOnServer.value
          : this.hasMoreOnServer,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MailboxRow(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('path: $path, ')
          ..write('encodedPath: $encodedPath, ')
          ..write('name: $name, ')
          ..write('specialUse: $specialUse, ')
          ..write('delimiter: $delimiter, ')
          ..write('uidValidity: $uidValidity, ')
          ..write('uidNext: $uidNext, ')
          ..write('highestModSeq: $highestModSeq, ')
          ..write('totalCount: $totalCount, ')
          ..write('unreadCount: $unreadCount, ')
          ..write('isSubscribed: $isSubscribed, ')
          ..write('isSelectable: $isSelectable, ')
          ..write('lastSyncAt: $lastSyncAt, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('hasMoreOnServer: $hasMoreOnServer')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    accountId,
    path,
    encodedPath,
    name,
    specialUse,
    delimiter,
    uidValidity,
    uidNext,
    highestModSeq,
    totalCount,
    unreadCount,
    isSubscribed,
    isSelectable,
    lastSyncAt,
    sortOrder,
    hasMoreOnServer,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MailboxRow &&
          other.id == this.id &&
          other.accountId == this.accountId &&
          other.path == this.path &&
          other.encodedPath == this.encodedPath &&
          other.name == this.name &&
          other.specialUse == this.specialUse &&
          other.delimiter == this.delimiter &&
          other.uidValidity == this.uidValidity &&
          other.uidNext == this.uidNext &&
          other.highestModSeq == this.highestModSeq &&
          other.totalCount == this.totalCount &&
          other.unreadCount == this.unreadCount &&
          other.isSubscribed == this.isSubscribed &&
          other.isSelectable == this.isSelectable &&
          other.lastSyncAt == this.lastSyncAt &&
          other.sortOrder == this.sortOrder &&
          other.hasMoreOnServer == this.hasMoreOnServer);
}

class MailboxesCompanion extends UpdateCompanion<MailboxRow> {
  final Value<int> id;
  final Value<int> accountId;
  final Value<String> path;
  final Value<String> encodedPath;
  final Value<String> name;
  final Value<SpecialUse> specialUse;
  final Value<String> delimiter;
  final Value<int?> uidValidity;
  final Value<int?> uidNext;
  final Value<int?> highestModSeq;
  final Value<int> totalCount;
  final Value<int> unreadCount;
  final Value<bool> isSubscribed;
  final Value<bool> isSelectable;
  final Value<DateTime?> lastSyncAt;
  final Value<int> sortOrder;
  final Value<bool> hasMoreOnServer;
  const MailboxesCompanion({
    this.id = const Value.absent(),
    this.accountId = const Value.absent(),
    this.path = const Value.absent(),
    this.encodedPath = const Value.absent(),
    this.name = const Value.absent(),
    this.specialUse = const Value.absent(),
    this.delimiter = const Value.absent(),
    this.uidValidity = const Value.absent(),
    this.uidNext = const Value.absent(),
    this.highestModSeq = const Value.absent(),
    this.totalCount = const Value.absent(),
    this.unreadCount = const Value.absent(),
    this.isSubscribed = const Value.absent(),
    this.isSelectable = const Value.absent(),
    this.lastSyncAt = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.hasMoreOnServer = const Value.absent(),
  });
  MailboxesCompanion.insert({
    this.id = const Value.absent(),
    required int accountId,
    required String path,
    this.encodedPath = const Value.absent(),
    required String name,
    this.specialUse = const Value.absent(),
    this.delimiter = const Value.absent(),
    this.uidValidity = const Value.absent(),
    this.uidNext = const Value.absent(),
    this.highestModSeq = const Value.absent(),
    this.totalCount = const Value.absent(),
    this.unreadCount = const Value.absent(),
    this.isSubscribed = const Value.absent(),
    this.isSelectable = const Value.absent(),
    this.lastSyncAt = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.hasMoreOnServer = const Value.absent(),
  }) : accountId = Value(accountId),
       path = Value(path),
       name = Value(name);
  static Insertable<MailboxRow> custom({
    Expression<int>? id,
    Expression<int>? accountId,
    Expression<String>? path,
    Expression<String>? encodedPath,
    Expression<String>? name,
    Expression<int>? specialUse,
    Expression<String>? delimiter,
    Expression<int>? uidValidity,
    Expression<int>? uidNext,
    Expression<int>? highestModSeq,
    Expression<int>? totalCount,
    Expression<int>? unreadCount,
    Expression<bool>? isSubscribed,
    Expression<bool>? isSelectable,
    Expression<DateTime>? lastSyncAt,
    Expression<int>? sortOrder,
    Expression<bool>? hasMoreOnServer,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (accountId != null) 'account_id': accountId,
      if (path != null) 'path': path,
      if (encodedPath != null) 'encoded_path': encodedPath,
      if (name != null) 'name': name,
      if (specialUse != null) 'special_use': specialUse,
      if (delimiter != null) 'delimiter': delimiter,
      if (uidValidity != null) 'uid_validity': uidValidity,
      if (uidNext != null) 'uid_next': uidNext,
      if (highestModSeq != null) 'highest_mod_seq': highestModSeq,
      if (totalCount != null) 'total_count': totalCount,
      if (unreadCount != null) 'unread_count': unreadCount,
      if (isSubscribed != null) 'is_subscribed': isSubscribed,
      if (isSelectable != null) 'is_selectable': isSelectable,
      if (lastSyncAt != null) 'last_sync_at': lastSyncAt,
      if (sortOrder != null) 'sort_order': sortOrder,
      if (hasMoreOnServer != null) 'has_more_on_server': hasMoreOnServer,
    });
  }

  MailboxesCompanion copyWith({
    Value<int>? id,
    Value<int>? accountId,
    Value<String>? path,
    Value<String>? encodedPath,
    Value<String>? name,
    Value<SpecialUse>? specialUse,
    Value<String>? delimiter,
    Value<int?>? uidValidity,
    Value<int?>? uidNext,
    Value<int?>? highestModSeq,
    Value<int>? totalCount,
    Value<int>? unreadCount,
    Value<bool>? isSubscribed,
    Value<bool>? isSelectable,
    Value<DateTime?>? lastSyncAt,
    Value<int>? sortOrder,
    Value<bool>? hasMoreOnServer,
  }) {
    return MailboxesCompanion(
      id: id ?? this.id,
      accountId: accountId ?? this.accountId,
      path: path ?? this.path,
      encodedPath: encodedPath ?? this.encodedPath,
      name: name ?? this.name,
      specialUse: specialUse ?? this.specialUse,
      delimiter: delimiter ?? this.delimiter,
      uidValidity: uidValidity ?? this.uidValidity,
      uidNext: uidNext ?? this.uidNext,
      highestModSeq: highestModSeq ?? this.highestModSeq,
      totalCount: totalCount ?? this.totalCount,
      unreadCount: unreadCount ?? this.unreadCount,
      isSubscribed: isSubscribed ?? this.isSubscribed,
      isSelectable: isSelectable ?? this.isSelectable,
      lastSyncAt: lastSyncAt ?? this.lastSyncAt,
      sortOrder: sortOrder ?? this.sortOrder,
      hasMoreOnServer: hasMoreOnServer ?? this.hasMoreOnServer,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (accountId.present) {
      map['account_id'] = Variable<int>(accountId.value);
    }
    if (path.present) {
      map['path'] = Variable<String>(path.value);
    }
    if (encodedPath.present) {
      map['encoded_path'] = Variable<String>(encodedPath.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (specialUse.present) {
      map['special_use'] = Variable<int>(
        $MailboxesTable.$converterspecialUse.toSql(specialUse.value),
      );
    }
    if (delimiter.present) {
      map['delimiter'] = Variable<String>(delimiter.value);
    }
    if (uidValidity.present) {
      map['uid_validity'] = Variable<int>(uidValidity.value);
    }
    if (uidNext.present) {
      map['uid_next'] = Variable<int>(uidNext.value);
    }
    if (highestModSeq.present) {
      map['highest_mod_seq'] = Variable<int>(highestModSeq.value);
    }
    if (totalCount.present) {
      map['total_count'] = Variable<int>(totalCount.value);
    }
    if (unreadCount.present) {
      map['unread_count'] = Variable<int>(unreadCount.value);
    }
    if (isSubscribed.present) {
      map['is_subscribed'] = Variable<bool>(isSubscribed.value);
    }
    if (isSelectable.present) {
      map['is_selectable'] = Variable<bool>(isSelectable.value);
    }
    if (lastSyncAt.present) {
      map['last_sync_at'] = Variable<DateTime>(lastSyncAt.value);
    }
    if (sortOrder.present) {
      map['sort_order'] = Variable<int>(sortOrder.value);
    }
    if (hasMoreOnServer.present) {
      map['has_more_on_server'] = Variable<bool>(hasMoreOnServer.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MailboxesCompanion(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('path: $path, ')
          ..write('encodedPath: $encodedPath, ')
          ..write('name: $name, ')
          ..write('specialUse: $specialUse, ')
          ..write('delimiter: $delimiter, ')
          ..write('uidValidity: $uidValidity, ')
          ..write('uidNext: $uidNext, ')
          ..write('highestModSeq: $highestModSeq, ')
          ..write('totalCount: $totalCount, ')
          ..write('unreadCount: $unreadCount, ')
          ..write('isSubscribed: $isSubscribed, ')
          ..write('isSelectable: $isSelectable, ')
          ..write('lastSyncAt: $lastSyncAt, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('hasMoreOnServer: $hasMoreOnServer')
          ..write(')'))
        .toString();
  }
}

class $MessagesTable extends Messages
    with TableInfo<$MessagesTable, MessageRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MessagesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _accountIdMeta = const VerificationMeta(
    'accountId',
  );
  @override
  late final GeneratedColumn<int> accountId = GeneratedColumn<int>(
    'account_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES accounts (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _mailboxIdMeta = const VerificationMeta(
    'mailboxId',
  );
  @override
  late final GeneratedColumn<int> mailboxId = GeneratedColumn<int>(
    'mailbox_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES mailboxes (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _uidMeta = const VerificationMeta('uid');
  @override
  late final GeneratedColumn<int> uid = GeneratedColumn<int>(
    'uid',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _messageIdHeaderMeta = const VerificationMeta(
    'messageIdHeader',
  );
  @override
  late final GeneratedColumn<String> messageIdHeader = GeneratedColumn<String>(
    'message_id_header',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _inReplyToMeta = const VerificationMeta(
    'inReplyTo',
  );
  @override
  late final GeneratedColumn<String> inReplyTo = GeneratedColumn<String>(
    'in_reply_to',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _referencesRawMeta = const VerificationMeta(
    'referencesRaw',
  );
  @override
  late final GeneratedColumn<String> referencesRaw = GeneratedColumn<String>(
    'references_raw',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _threadIdMeta = const VerificationMeta(
    'threadId',
  );
  @override
  late final GeneratedColumn<String> threadId = GeneratedColumn<String>(
    'thread_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _fromNameMeta = const VerificationMeta(
    'fromName',
  );
  @override
  late final GeneratedColumn<String> fromName = GeneratedColumn<String>(
    'from_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _fromEmailMeta = const VerificationMeta(
    'fromEmail',
  );
  @override
  late final GeneratedColumn<String> fromEmail = GeneratedColumn<String>(
    'from_email',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _toAddrJsonMeta = const VerificationMeta(
    'toAddrJson',
  );
  @override
  late final GeneratedColumn<String> toAddrJson = GeneratedColumn<String>(
    'to_addr_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('[]'),
  );
  static const VerificationMeta _ccJsonMeta = const VerificationMeta('ccJson');
  @override
  late final GeneratedColumn<String> ccJson = GeneratedColumn<String>(
    'cc_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('[]'),
  );
  static const VerificationMeta _bccJsonMeta = const VerificationMeta(
    'bccJson',
  );
  @override
  late final GeneratedColumn<String> bccJson = GeneratedColumn<String>(
    'bcc_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('[]'),
  );
  static const VerificationMeta _subjectMeta = const VerificationMeta(
    'subject',
  );
  @override
  late final GeneratedColumn<String> subject = GeneratedColumn<String>(
    'subject',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _subjectNormalizedMeta = const VerificationMeta(
    'subjectNormalized',
  );
  @override
  late final GeneratedColumn<String> subjectNormalized =
      GeneratedColumn<String>(
        'subject_normalized',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
        defaultValue: const Constant(''),
      );
  static const VerificationMeta _previewMeta = const VerificationMeta(
    'preview',
  );
  @override
  late final GeneratedColumn<String> preview = GeneratedColumn<String>(
    'preview',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _dateUtcMeta = const VerificationMeta(
    'dateUtc',
  );
  @override
  late final GeneratedColumn<DateTime> dateUtc = GeneratedColumn<DateTime>(
    'date_utc',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _isSeenMeta = const VerificationMeta('isSeen');
  @override
  late final GeneratedColumn<bool> isSeen = GeneratedColumn<bool>(
    'is_seen',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_seen" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _isFlaggedMeta = const VerificationMeta(
    'isFlagged',
  );
  @override
  late final GeneratedColumn<bool> isFlagged = GeneratedColumn<bool>(
    'is_flagged',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_flagged" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _isAnsweredMeta = const VerificationMeta(
    'isAnswered',
  );
  @override
  late final GeneratedColumn<bool> isAnswered = GeneratedColumn<bool>(
    'is_answered',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_answered" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _isDraftMeta = const VerificationMeta(
    'isDraft',
  );
  @override
  late final GeneratedColumn<bool> isDraft = GeneratedColumn<bool>(
    'is_draft',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_draft" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _isDeletedMeta = const VerificationMeta(
    'isDeleted',
  );
  @override
  late final GeneratedColumn<bool> isDeleted = GeneratedColumn<bool>(
    'is_deleted',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_deleted" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _hasAttachmentsMeta = const VerificationMeta(
    'hasAttachments',
  );
  @override
  late final GeneratedColumn<bool> hasAttachments = GeneratedColumn<bool>(
    'has_attachments',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("has_attachments" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _sizeBytesMeta = const VerificationMeta(
    'sizeBytes',
  );
  @override
  late final GeneratedColumn<int> sizeBytes = GeneratedColumn<int>(
    'size_bytes',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _bodyFetchedAtMeta = const VerificationMeta(
    'bodyFetchedAt',
  );
  @override
  late final GeneratedColumn<DateTime> bodyFetchedAt =
      GeneratedColumn<DateTime>(
        'body_fetched_at',
        aliasedName,
        true,
        type: DriftSqlType.dateTime,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _labelsJsonMeta = const VerificationMeta(
    'labelsJson',
  );
  @override
  late final GeneratedColumn<String> labelsJson = GeneratedColumn<String>(
    'labels_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('[]'),
  );
  static const VerificationMeta _isLocalOnlyMeta = const VerificationMeta(
    'isLocalOnly',
  );
  @override
  late final GeneratedColumn<bool> isLocalOnly = GeneratedColumn<bool>(
    'is_local_only',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_local_only" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  @override
  late final GeneratedColumnWithTypeConverter<OutboxState, int> outboxState =
      GeneratedColumn<int>(
        'outbox_state',
        aliasedName,
        false,
        type: DriftSqlType.int,
        requiredDuringInsert: false,
        defaultValue: const Constant(0),
      ).withConverter<OutboxState>($MessagesTable.$converteroutboxState);
  static const VerificationMeta _outboxErrorMeta = const VerificationMeta(
    'outboxError',
  );
  @override
  late final GeneratedColumn<String> outboxError = GeneratedColumn<String>(
    'outbox_error',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _replyToMessageIdMeta = const VerificationMeta(
    'replyToMessageId',
  );
  @override
  late final GeneratedColumn<int> replyToMessageId = GeneratedColumn<int>(
    'reply_to_message_id',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    accountId,
    mailboxId,
    uid,
    messageIdHeader,
    inReplyTo,
    referencesRaw,
    threadId,
    fromName,
    fromEmail,
    toAddrJson,
    ccJson,
    bccJson,
    subject,
    subjectNormalized,
    preview,
    dateUtc,
    isSeen,
    isFlagged,
    isAnswered,
    isDraft,
    isDeleted,
    hasAttachments,
    sizeBytes,
    bodyFetchedAt,
    labelsJson,
    isLocalOnly,
    outboxState,
    outboxError,
    replyToMessageId,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'messages';
  @override
  VerificationContext validateIntegrity(
    Insertable<MessageRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('account_id')) {
      context.handle(
        _accountIdMeta,
        accountId.isAcceptableOrUnknown(data['account_id']!, _accountIdMeta),
      );
    } else if (isInserting) {
      context.missing(_accountIdMeta);
    }
    if (data.containsKey('mailbox_id')) {
      context.handle(
        _mailboxIdMeta,
        mailboxId.isAcceptableOrUnknown(data['mailbox_id']!, _mailboxIdMeta),
      );
    } else if (isInserting) {
      context.missing(_mailboxIdMeta);
    }
    if (data.containsKey('uid')) {
      context.handle(
        _uidMeta,
        uid.isAcceptableOrUnknown(data['uid']!, _uidMeta),
      );
    }
    if (data.containsKey('message_id_header')) {
      context.handle(
        _messageIdHeaderMeta,
        messageIdHeader.isAcceptableOrUnknown(
          data['message_id_header']!,
          _messageIdHeaderMeta,
        ),
      );
    }
    if (data.containsKey('in_reply_to')) {
      context.handle(
        _inReplyToMeta,
        inReplyTo.isAcceptableOrUnknown(data['in_reply_to']!, _inReplyToMeta),
      );
    }
    if (data.containsKey('references_raw')) {
      context.handle(
        _referencesRawMeta,
        referencesRaw.isAcceptableOrUnknown(
          data['references_raw']!,
          _referencesRawMeta,
        ),
      );
    }
    if (data.containsKey('thread_id')) {
      context.handle(
        _threadIdMeta,
        threadId.isAcceptableOrUnknown(data['thread_id']!, _threadIdMeta),
      );
    }
    if (data.containsKey('from_name')) {
      context.handle(
        _fromNameMeta,
        fromName.isAcceptableOrUnknown(data['from_name']!, _fromNameMeta),
      );
    }
    if (data.containsKey('from_email')) {
      context.handle(
        _fromEmailMeta,
        fromEmail.isAcceptableOrUnknown(data['from_email']!, _fromEmailMeta),
      );
    }
    if (data.containsKey('to_addr_json')) {
      context.handle(
        _toAddrJsonMeta,
        toAddrJson.isAcceptableOrUnknown(
          data['to_addr_json']!,
          _toAddrJsonMeta,
        ),
      );
    }
    if (data.containsKey('cc_json')) {
      context.handle(
        _ccJsonMeta,
        ccJson.isAcceptableOrUnknown(data['cc_json']!, _ccJsonMeta),
      );
    }
    if (data.containsKey('bcc_json')) {
      context.handle(
        _bccJsonMeta,
        bccJson.isAcceptableOrUnknown(data['bcc_json']!, _bccJsonMeta),
      );
    }
    if (data.containsKey('subject')) {
      context.handle(
        _subjectMeta,
        subject.isAcceptableOrUnknown(data['subject']!, _subjectMeta),
      );
    }
    if (data.containsKey('subject_normalized')) {
      context.handle(
        _subjectNormalizedMeta,
        subjectNormalized.isAcceptableOrUnknown(
          data['subject_normalized']!,
          _subjectNormalizedMeta,
        ),
      );
    }
    if (data.containsKey('preview')) {
      context.handle(
        _previewMeta,
        preview.isAcceptableOrUnknown(data['preview']!, _previewMeta),
      );
    }
    if (data.containsKey('date_utc')) {
      context.handle(
        _dateUtcMeta,
        dateUtc.isAcceptableOrUnknown(data['date_utc']!, _dateUtcMeta),
      );
    } else if (isInserting) {
      context.missing(_dateUtcMeta);
    }
    if (data.containsKey('is_seen')) {
      context.handle(
        _isSeenMeta,
        isSeen.isAcceptableOrUnknown(data['is_seen']!, _isSeenMeta),
      );
    }
    if (data.containsKey('is_flagged')) {
      context.handle(
        _isFlaggedMeta,
        isFlagged.isAcceptableOrUnknown(data['is_flagged']!, _isFlaggedMeta),
      );
    }
    if (data.containsKey('is_answered')) {
      context.handle(
        _isAnsweredMeta,
        isAnswered.isAcceptableOrUnknown(data['is_answered']!, _isAnsweredMeta),
      );
    }
    if (data.containsKey('is_draft')) {
      context.handle(
        _isDraftMeta,
        isDraft.isAcceptableOrUnknown(data['is_draft']!, _isDraftMeta),
      );
    }
    if (data.containsKey('is_deleted')) {
      context.handle(
        _isDeletedMeta,
        isDeleted.isAcceptableOrUnknown(data['is_deleted']!, _isDeletedMeta),
      );
    }
    if (data.containsKey('has_attachments')) {
      context.handle(
        _hasAttachmentsMeta,
        hasAttachments.isAcceptableOrUnknown(
          data['has_attachments']!,
          _hasAttachmentsMeta,
        ),
      );
    }
    if (data.containsKey('size_bytes')) {
      context.handle(
        _sizeBytesMeta,
        sizeBytes.isAcceptableOrUnknown(data['size_bytes']!, _sizeBytesMeta),
      );
    }
    if (data.containsKey('body_fetched_at')) {
      context.handle(
        _bodyFetchedAtMeta,
        bodyFetchedAt.isAcceptableOrUnknown(
          data['body_fetched_at']!,
          _bodyFetchedAtMeta,
        ),
      );
    }
    if (data.containsKey('labels_json')) {
      context.handle(
        _labelsJsonMeta,
        labelsJson.isAcceptableOrUnknown(data['labels_json']!, _labelsJsonMeta),
      );
    }
    if (data.containsKey('is_local_only')) {
      context.handle(
        _isLocalOnlyMeta,
        isLocalOnly.isAcceptableOrUnknown(
          data['is_local_only']!,
          _isLocalOnlyMeta,
        ),
      );
    }
    if (data.containsKey('outbox_error')) {
      context.handle(
        _outboxErrorMeta,
        outboxError.isAcceptableOrUnknown(
          data['outbox_error']!,
          _outboxErrorMeta,
        ),
      );
    }
    if (data.containsKey('reply_to_message_id')) {
      context.handle(
        _replyToMessageIdMeta,
        replyToMessageId.isAcceptableOrUnknown(
          data['reply_to_message_id']!,
          _replyToMessageIdMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  MessageRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MessageRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}account_id'],
      )!,
      mailboxId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}mailbox_id'],
      )!,
      uid: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}uid'],
      ),
      messageIdHeader: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}message_id_header'],
      ),
      inReplyTo: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}in_reply_to'],
      ),
      referencesRaw: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}references_raw'],
      ),
      threadId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}thread_id'],
      )!,
      fromName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}from_name'],
      )!,
      fromEmail: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}from_email'],
      )!,
      toAddrJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}to_addr_json'],
      )!,
      ccJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}cc_json'],
      )!,
      bccJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}bcc_json'],
      )!,
      subject: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}subject'],
      )!,
      subjectNormalized: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}subject_normalized'],
      )!,
      preview: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}preview'],
      )!,
      dateUtc: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}date_utc'],
      )!,
      isSeen: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_seen'],
      )!,
      isFlagged: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_flagged'],
      )!,
      isAnswered: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_answered'],
      )!,
      isDraft: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_draft'],
      )!,
      isDeleted: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_deleted'],
      )!,
      hasAttachments: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}has_attachments'],
      )!,
      sizeBytes: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}size_bytes'],
      )!,
      bodyFetchedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}body_fetched_at'],
      ),
      labelsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}labels_json'],
      )!,
      isLocalOnly: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_local_only'],
      )!,
      outboxState: $MessagesTable.$converteroutboxState.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.int,
          data['${effectivePrefix}outbox_state'],
        )!,
      ),
      outboxError: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}outbox_error'],
      ),
      replyToMessageId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}reply_to_message_id'],
      ),
    );
  }

  @override
  $MessagesTable createAlias(String alias) {
    return $MessagesTable(attachedDatabase, alias);
  }

  static JsonTypeConverter2<OutboxState, int, int> $converteroutboxState =
      const EnumIndexConverter<OutboxState>(OutboxState.values);
}

class MessageRow extends DataClass implements Insertable<MessageRow> {
  final int id;
  final int accountId;
  final int mailboxId;

  /// Sunucudaki UID. Yerel (henüz gönderilmemiş) iletilerde `null`.
  final int? uid;
  final String? messageIdHeader;
  final String? inReplyTo;
  final String? referencesRaw;

  /// Yerel hesaplanan konuşma kimliği.
  final String threadId;
  final String fromName;
  final String fromEmail;
  final String toAddrJson;
  final String ccJson;
  final String bccJson;
  final String subject;
  final String subjectNormalized;
  final String preview;
  final DateTime dateUtc;
  final bool isSeen;
  final bool isFlagged;
  final bool isAnswered;
  final bool isDraft;
  final bool isDeleted;
  final bool hasAttachments;
  final int sizeBytes;
  final DateTime? bodyFetchedAt;
  final String labelsJson;

  /// Sunucuda karşılığı olmayan yerel ileti (taslak / giden kutusu).
  final bool isLocalOnly;
  final OutboxState outboxState;
  final String? outboxError;

  /// Yanıt/iletme oluştururken kaynak iletiye bağlanmak için.
  final int? replyToMessageId;
  const MessageRow({
    required this.id,
    required this.accountId,
    required this.mailboxId,
    this.uid,
    this.messageIdHeader,
    this.inReplyTo,
    this.referencesRaw,
    required this.threadId,
    required this.fromName,
    required this.fromEmail,
    required this.toAddrJson,
    required this.ccJson,
    required this.bccJson,
    required this.subject,
    required this.subjectNormalized,
    required this.preview,
    required this.dateUtc,
    required this.isSeen,
    required this.isFlagged,
    required this.isAnswered,
    required this.isDraft,
    required this.isDeleted,
    required this.hasAttachments,
    required this.sizeBytes,
    this.bodyFetchedAt,
    required this.labelsJson,
    required this.isLocalOnly,
    required this.outboxState,
    this.outboxError,
    this.replyToMessageId,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['account_id'] = Variable<int>(accountId);
    map['mailbox_id'] = Variable<int>(mailboxId);
    if (!nullToAbsent || uid != null) {
      map['uid'] = Variable<int>(uid);
    }
    if (!nullToAbsent || messageIdHeader != null) {
      map['message_id_header'] = Variable<String>(messageIdHeader);
    }
    if (!nullToAbsent || inReplyTo != null) {
      map['in_reply_to'] = Variable<String>(inReplyTo);
    }
    if (!nullToAbsent || referencesRaw != null) {
      map['references_raw'] = Variable<String>(referencesRaw);
    }
    map['thread_id'] = Variable<String>(threadId);
    map['from_name'] = Variable<String>(fromName);
    map['from_email'] = Variable<String>(fromEmail);
    map['to_addr_json'] = Variable<String>(toAddrJson);
    map['cc_json'] = Variable<String>(ccJson);
    map['bcc_json'] = Variable<String>(bccJson);
    map['subject'] = Variable<String>(subject);
    map['subject_normalized'] = Variable<String>(subjectNormalized);
    map['preview'] = Variable<String>(preview);
    map['date_utc'] = Variable<DateTime>(dateUtc);
    map['is_seen'] = Variable<bool>(isSeen);
    map['is_flagged'] = Variable<bool>(isFlagged);
    map['is_answered'] = Variable<bool>(isAnswered);
    map['is_draft'] = Variable<bool>(isDraft);
    map['is_deleted'] = Variable<bool>(isDeleted);
    map['has_attachments'] = Variable<bool>(hasAttachments);
    map['size_bytes'] = Variable<int>(sizeBytes);
    if (!nullToAbsent || bodyFetchedAt != null) {
      map['body_fetched_at'] = Variable<DateTime>(bodyFetchedAt);
    }
    map['labels_json'] = Variable<String>(labelsJson);
    map['is_local_only'] = Variable<bool>(isLocalOnly);
    {
      map['outbox_state'] = Variable<int>(
        $MessagesTable.$converteroutboxState.toSql(outboxState),
      );
    }
    if (!nullToAbsent || outboxError != null) {
      map['outbox_error'] = Variable<String>(outboxError);
    }
    if (!nullToAbsent || replyToMessageId != null) {
      map['reply_to_message_id'] = Variable<int>(replyToMessageId);
    }
    return map;
  }

  MessagesCompanion toCompanion(bool nullToAbsent) {
    return MessagesCompanion(
      id: Value(id),
      accountId: Value(accountId),
      mailboxId: Value(mailboxId),
      uid: uid == null && nullToAbsent ? const Value.absent() : Value(uid),
      messageIdHeader: messageIdHeader == null && nullToAbsent
          ? const Value.absent()
          : Value(messageIdHeader),
      inReplyTo: inReplyTo == null && nullToAbsent
          ? const Value.absent()
          : Value(inReplyTo),
      referencesRaw: referencesRaw == null && nullToAbsent
          ? const Value.absent()
          : Value(referencesRaw),
      threadId: Value(threadId),
      fromName: Value(fromName),
      fromEmail: Value(fromEmail),
      toAddrJson: Value(toAddrJson),
      ccJson: Value(ccJson),
      bccJson: Value(bccJson),
      subject: Value(subject),
      subjectNormalized: Value(subjectNormalized),
      preview: Value(preview),
      dateUtc: Value(dateUtc),
      isSeen: Value(isSeen),
      isFlagged: Value(isFlagged),
      isAnswered: Value(isAnswered),
      isDraft: Value(isDraft),
      isDeleted: Value(isDeleted),
      hasAttachments: Value(hasAttachments),
      sizeBytes: Value(sizeBytes),
      bodyFetchedAt: bodyFetchedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(bodyFetchedAt),
      labelsJson: Value(labelsJson),
      isLocalOnly: Value(isLocalOnly),
      outboxState: Value(outboxState),
      outboxError: outboxError == null && nullToAbsent
          ? const Value.absent()
          : Value(outboxError),
      replyToMessageId: replyToMessageId == null && nullToAbsent
          ? const Value.absent()
          : Value(replyToMessageId),
    );
  }

  factory MessageRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MessageRow(
      id: serializer.fromJson<int>(json['id']),
      accountId: serializer.fromJson<int>(json['accountId']),
      mailboxId: serializer.fromJson<int>(json['mailboxId']),
      uid: serializer.fromJson<int?>(json['uid']),
      messageIdHeader: serializer.fromJson<String?>(json['messageIdHeader']),
      inReplyTo: serializer.fromJson<String?>(json['inReplyTo']),
      referencesRaw: serializer.fromJson<String?>(json['referencesRaw']),
      threadId: serializer.fromJson<String>(json['threadId']),
      fromName: serializer.fromJson<String>(json['fromName']),
      fromEmail: serializer.fromJson<String>(json['fromEmail']),
      toAddrJson: serializer.fromJson<String>(json['toAddrJson']),
      ccJson: serializer.fromJson<String>(json['ccJson']),
      bccJson: serializer.fromJson<String>(json['bccJson']),
      subject: serializer.fromJson<String>(json['subject']),
      subjectNormalized: serializer.fromJson<String>(json['subjectNormalized']),
      preview: serializer.fromJson<String>(json['preview']),
      dateUtc: serializer.fromJson<DateTime>(json['dateUtc']),
      isSeen: serializer.fromJson<bool>(json['isSeen']),
      isFlagged: serializer.fromJson<bool>(json['isFlagged']),
      isAnswered: serializer.fromJson<bool>(json['isAnswered']),
      isDraft: serializer.fromJson<bool>(json['isDraft']),
      isDeleted: serializer.fromJson<bool>(json['isDeleted']),
      hasAttachments: serializer.fromJson<bool>(json['hasAttachments']),
      sizeBytes: serializer.fromJson<int>(json['sizeBytes']),
      bodyFetchedAt: serializer.fromJson<DateTime?>(json['bodyFetchedAt']),
      labelsJson: serializer.fromJson<String>(json['labelsJson']),
      isLocalOnly: serializer.fromJson<bool>(json['isLocalOnly']),
      outboxState: $MessagesTable.$converteroutboxState.fromJson(
        serializer.fromJson<int>(json['outboxState']),
      ),
      outboxError: serializer.fromJson<String?>(json['outboxError']),
      replyToMessageId: serializer.fromJson<int?>(json['replyToMessageId']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'accountId': serializer.toJson<int>(accountId),
      'mailboxId': serializer.toJson<int>(mailboxId),
      'uid': serializer.toJson<int?>(uid),
      'messageIdHeader': serializer.toJson<String?>(messageIdHeader),
      'inReplyTo': serializer.toJson<String?>(inReplyTo),
      'referencesRaw': serializer.toJson<String?>(referencesRaw),
      'threadId': serializer.toJson<String>(threadId),
      'fromName': serializer.toJson<String>(fromName),
      'fromEmail': serializer.toJson<String>(fromEmail),
      'toAddrJson': serializer.toJson<String>(toAddrJson),
      'ccJson': serializer.toJson<String>(ccJson),
      'bccJson': serializer.toJson<String>(bccJson),
      'subject': serializer.toJson<String>(subject),
      'subjectNormalized': serializer.toJson<String>(subjectNormalized),
      'preview': serializer.toJson<String>(preview),
      'dateUtc': serializer.toJson<DateTime>(dateUtc),
      'isSeen': serializer.toJson<bool>(isSeen),
      'isFlagged': serializer.toJson<bool>(isFlagged),
      'isAnswered': serializer.toJson<bool>(isAnswered),
      'isDraft': serializer.toJson<bool>(isDraft),
      'isDeleted': serializer.toJson<bool>(isDeleted),
      'hasAttachments': serializer.toJson<bool>(hasAttachments),
      'sizeBytes': serializer.toJson<int>(sizeBytes),
      'bodyFetchedAt': serializer.toJson<DateTime?>(bodyFetchedAt),
      'labelsJson': serializer.toJson<String>(labelsJson),
      'isLocalOnly': serializer.toJson<bool>(isLocalOnly),
      'outboxState': serializer.toJson<int>(
        $MessagesTable.$converteroutboxState.toJson(outboxState),
      ),
      'outboxError': serializer.toJson<String?>(outboxError),
      'replyToMessageId': serializer.toJson<int?>(replyToMessageId),
    };
  }

  MessageRow copyWith({
    int? id,
    int? accountId,
    int? mailboxId,
    Value<int?> uid = const Value.absent(),
    Value<String?> messageIdHeader = const Value.absent(),
    Value<String?> inReplyTo = const Value.absent(),
    Value<String?> referencesRaw = const Value.absent(),
    String? threadId,
    String? fromName,
    String? fromEmail,
    String? toAddrJson,
    String? ccJson,
    String? bccJson,
    String? subject,
    String? subjectNormalized,
    String? preview,
    DateTime? dateUtc,
    bool? isSeen,
    bool? isFlagged,
    bool? isAnswered,
    bool? isDraft,
    bool? isDeleted,
    bool? hasAttachments,
    int? sizeBytes,
    Value<DateTime?> bodyFetchedAt = const Value.absent(),
    String? labelsJson,
    bool? isLocalOnly,
    OutboxState? outboxState,
    Value<String?> outboxError = const Value.absent(),
    Value<int?> replyToMessageId = const Value.absent(),
  }) => MessageRow(
    id: id ?? this.id,
    accountId: accountId ?? this.accountId,
    mailboxId: mailboxId ?? this.mailboxId,
    uid: uid.present ? uid.value : this.uid,
    messageIdHeader: messageIdHeader.present
        ? messageIdHeader.value
        : this.messageIdHeader,
    inReplyTo: inReplyTo.present ? inReplyTo.value : this.inReplyTo,
    referencesRaw: referencesRaw.present
        ? referencesRaw.value
        : this.referencesRaw,
    threadId: threadId ?? this.threadId,
    fromName: fromName ?? this.fromName,
    fromEmail: fromEmail ?? this.fromEmail,
    toAddrJson: toAddrJson ?? this.toAddrJson,
    ccJson: ccJson ?? this.ccJson,
    bccJson: bccJson ?? this.bccJson,
    subject: subject ?? this.subject,
    subjectNormalized: subjectNormalized ?? this.subjectNormalized,
    preview: preview ?? this.preview,
    dateUtc: dateUtc ?? this.dateUtc,
    isSeen: isSeen ?? this.isSeen,
    isFlagged: isFlagged ?? this.isFlagged,
    isAnswered: isAnswered ?? this.isAnswered,
    isDraft: isDraft ?? this.isDraft,
    isDeleted: isDeleted ?? this.isDeleted,
    hasAttachments: hasAttachments ?? this.hasAttachments,
    sizeBytes: sizeBytes ?? this.sizeBytes,
    bodyFetchedAt: bodyFetchedAt.present
        ? bodyFetchedAt.value
        : this.bodyFetchedAt,
    labelsJson: labelsJson ?? this.labelsJson,
    isLocalOnly: isLocalOnly ?? this.isLocalOnly,
    outboxState: outboxState ?? this.outboxState,
    outboxError: outboxError.present ? outboxError.value : this.outboxError,
    replyToMessageId: replyToMessageId.present
        ? replyToMessageId.value
        : this.replyToMessageId,
  );
  MessageRow copyWithCompanion(MessagesCompanion data) {
    return MessageRow(
      id: data.id.present ? data.id.value : this.id,
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      mailboxId: data.mailboxId.present ? data.mailboxId.value : this.mailboxId,
      uid: data.uid.present ? data.uid.value : this.uid,
      messageIdHeader: data.messageIdHeader.present
          ? data.messageIdHeader.value
          : this.messageIdHeader,
      inReplyTo: data.inReplyTo.present ? data.inReplyTo.value : this.inReplyTo,
      referencesRaw: data.referencesRaw.present
          ? data.referencesRaw.value
          : this.referencesRaw,
      threadId: data.threadId.present ? data.threadId.value : this.threadId,
      fromName: data.fromName.present ? data.fromName.value : this.fromName,
      fromEmail: data.fromEmail.present ? data.fromEmail.value : this.fromEmail,
      toAddrJson: data.toAddrJson.present
          ? data.toAddrJson.value
          : this.toAddrJson,
      ccJson: data.ccJson.present ? data.ccJson.value : this.ccJson,
      bccJson: data.bccJson.present ? data.bccJson.value : this.bccJson,
      subject: data.subject.present ? data.subject.value : this.subject,
      subjectNormalized: data.subjectNormalized.present
          ? data.subjectNormalized.value
          : this.subjectNormalized,
      preview: data.preview.present ? data.preview.value : this.preview,
      dateUtc: data.dateUtc.present ? data.dateUtc.value : this.dateUtc,
      isSeen: data.isSeen.present ? data.isSeen.value : this.isSeen,
      isFlagged: data.isFlagged.present ? data.isFlagged.value : this.isFlagged,
      isAnswered: data.isAnswered.present
          ? data.isAnswered.value
          : this.isAnswered,
      isDraft: data.isDraft.present ? data.isDraft.value : this.isDraft,
      isDeleted: data.isDeleted.present ? data.isDeleted.value : this.isDeleted,
      hasAttachments: data.hasAttachments.present
          ? data.hasAttachments.value
          : this.hasAttachments,
      sizeBytes: data.sizeBytes.present ? data.sizeBytes.value : this.sizeBytes,
      bodyFetchedAt: data.bodyFetchedAt.present
          ? data.bodyFetchedAt.value
          : this.bodyFetchedAt,
      labelsJson: data.labelsJson.present
          ? data.labelsJson.value
          : this.labelsJson,
      isLocalOnly: data.isLocalOnly.present
          ? data.isLocalOnly.value
          : this.isLocalOnly,
      outboxState: data.outboxState.present
          ? data.outboxState.value
          : this.outboxState,
      outboxError: data.outboxError.present
          ? data.outboxError.value
          : this.outboxError,
      replyToMessageId: data.replyToMessageId.present
          ? data.replyToMessageId.value
          : this.replyToMessageId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MessageRow(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('mailboxId: $mailboxId, ')
          ..write('uid: $uid, ')
          ..write('messageIdHeader: $messageIdHeader, ')
          ..write('inReplyTo: $inReplyTo, ')
          ..write('referencesRaw: $referencesRaw, ')
          ..write('threadId: $threadId, ')
          ..write('fromName: $fromName, ')
          ..write('fromEmail: $fromEmail, ')
          ..write('toAddrJson: $toAddrJson, ')
          ..write('ccJson: $ccJson, ')
          ..write('bccJson: $bccJson, ')
          ..write('subject: $subject, ')
          ..write('subjectNormalized: $subjectNormalized, ')
          ..write('preview: $preview, ')
          ..write('dateUtc: $dateUtc, ')
          ..write('isSeen: $isSeen, ')
          ..write('isFlagged: $isFlagged, ')
          ..write('isAnswered: $isAnswered, ')
          ..write('isDraft: $isDraft, ')
          ..write('isDeleted: $isDeleted, ')
          ..write('hasAttachments: $hasAttachments, ')
          ..write('sizeBytes: $sizeBytes, ')
          ..write('bodyFetchedAt: $bodyFetchedAt, ')
          ..write('labelsJson: $labelsJson, ')
          ..write('isLocalOnly: $isLocalOnly, ')
          ..write('outboxState: $outboxState, ')
          ..write('outboxError: $outboxError, ')
          ..write('replyToMessageId: $replyToMessageId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hashAll([
    id,
    accountId,
    mailboxId,
    uid,
    messageIdHeader,
    inReplyTo,
    referencesRaw,
    threadId,
    fromName,
    fromEmail,
    toAddrJson,
    ccJson,
    bccJson,
    subject,
    subjectNormalized,
    preview,
    dateUtc,
    isSeen,
    isFlagged,
    isAnswered,
    isDraft,
    isDeleted,
    hasAttachments,
    sizeBytes,
    bodyFetchedAt,
    labelsJson,
    isLocalOnly,
    outboxState,
    outboxError,
    replyToMessageId,
  ]);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MessageRow &&
          other.id == this.id &&
          other.accountId == this.accountId &&
          other.mailboxId == this.mailboxId &&
          other.uid == this.uid &&
          other.messageIdHeader == this.messageIdHeader &&
          other.inReplyTo == this.inReplyTo &&
          other.referencesRaw == this.referencesRaw &&
          other.threadId == this.threadId &&
          other.fromName == this.fromName &&
          other.fromEmail == this.fromEmail &&
          other.toAddrJson == this.toAddrJson &&
          other.ccJson == this.ccJson &&
          other.bccJson == this.bccJson &&
          other.subject == this.subject &&
          other.subjectNormalized == this.subjectNormalized &&
          other.preview == this.preview &&
          other.dateUtc == this.dateUtc &&
          other.isSeen == this.isSeen &&
          other.isFlagged == this.isFlagged &&
          other.isAnswered == this.isAnswered &&
          other.isDraft == this.isDraft &&
          other.isDeleted == this.isDeleted &&
          other.hasAttachments == this.hasAttachments &&
          other.sizeBytes == this.sizeBytes &&
          other.bodyFetchedAt == this.bodyFetchedAt &&
          other.labelsJson == this.labelsJson &&
          other.isLocalOnly == this.isLocalOnly &&
          other.outboxState == this.outboxState &&
          other.outboxError == this.outboxError &&
          other.replyToMessageId == this.replyToMessageId);
}

class MessagesCompanion extends UpdateCompanion<MessageRow> {
  final Value<int> id;
  final Value<int> accountId;
  final Value<int> mailboxId;
  final Value<int?> uid;
  final Value<String?> messageIdHeader;
  final Value<String?> inReplyTo;
  final Value<String?> referencesRaw;
  final Value<String> threadId;
  final Value<String> fromName;
  final Value<String> fromEmail;
  final Value<String> toAddrJson;
  final Value<String> ccJson;
  final Value<String> bccJson;
  final Value<String> subject;
  final Value<String> subjectNormalized;
  final Value<String> preview;
  final Value<DateTime> dateUtc;
  final Value<bool> isSeen;
  final Value<bool> isFlagged;
  final Value<bool> isAnswered;
  final Value<bool> isDraft;
  final Value<bool> isDeleted;
  final Value<bool> hasAttachments;
  final Value<int> sizeBytes;
  final Value<DateTime?> bodyFetchedAt;
  final Value<String> labelsJson;
  final Value<bool> isLocalOnly;
  final Value<OutboxState> outboxState;
  final Value<String?> outboxError;
  final Value<int?> replyToMessageId;
  const MessagesCompanion({
    this.id = const Value.absent(),
    this.accountId = const Value.absent(),
    this.mailboxId = const Value.absent(),
    this.uid = const Value.absent(),
    this.messageIdHeader = const Value.absent(),
    this.inReplyTo = const Value.absent(),
    this.referencesRaw = const Value.absent(),
    this.threadId = const Value.absent(),
    this.fromName = const Value.absent(),
    this.fromEmail = const Value.absent(),
    this.toAddrJson = const Value.absent(),
    this.ccJson = const Value.absent(),
    this.bccJson = const Value.absent(),
    this.subject = const Value.absent(),
    this.subjectNormalized = const Value.absent(),
    this.preview = const Value.absent(),
    this.dateUtc = const Value.absent(),
    this.isSeen = const Value.absent(),
    this.isFlagged = const Value.absent(),
    this.isAnswered = const Value.absent(),
    this.isDraft = const Value.absent(),
    this.isDeleted = const Value.absent(),
    this.hasAttachments = const Value.absent(),
    this.sizeBytes = const Value.absent(),
    this.bodyFetchedAt = const Value.absent(),
    this.labelsJson = const Value.absent(),
    this.isLocalOnly = const Value.absent(),
    this.outboxState = const Value.absent(),
    this.outboxError = const Value.absent(),
    this.replyToMessageId = const Value.absent(),
  });
  MessagesCompanion.insert({
    this.id = const Value.absent(),
    required int accountId,
    required int mailboxId,
    this.uid = const Value.absent(),
    this.messageIdHeader = const Value.absent(),
    this.inReplyTo = const Value.absent(),
    this.referencesRaw = const Value.absent(),
    this.threadId = const Value.absent(),
    this.fromName = const Value.absent(),
    this.fromEmail = const Value.absent(),
    this.toAddrJson = const Value.absent(),
    this.ccJson = const Value.absent(),
    this.bccJson = const Value.absent(),
    this.subject = const Value.absent(),
    this.subjectNormalized = const Value.absent(),
    this.preview = const Value.absent(),
    required DateTime dateUtc,
    this.isSeen = const Value.absent(),
    this.isFlagged = const Value.absent(),
    this.isAnswered = const Value.absent(),
    this.isDraft = const Value.absent(),
    this.isDeleted = const Value.absent(),
    this.hasAttachments = const Value.absent(),
    this.sizeBytes = const Value.absent(),
    this.bodyFetchedAt = const Value.absent(),
    this.labelsJson = const Value.absent(),
    this.isLocalOnly = const Value.absent(),
    this.outboxState = const Value.absent(),
    this.outboxError = const Value.absent(),
    this.replyToMessageId = const Value.absent(),
  }) : accountId = Value(accountId),
       mailboxId = Value(mailboxId),
       dateUtc = Value(dateUtc);
  static Insertable<MessageRow> custom({
    Expression<int>? id,
    Expression<int>? accountId,
    Expression<int>? mailboxId,
    Expression<int>? uid,
    Expression<String>? messageIdHeader,
    Expression<String>? inReplyTo,
    Expression<String>? referencesRaw,
    Expression<String>? threadId,
    Expression<String>? fromName,
    Expression<String>? fromEmail,
    Expression<String>? toAddrJson,
    Expression<String>? ccJson,
    Expression<String>? bccJson,
    Expression<String>? subject,
    Expression<String>? subjectNormalized,
    Expression<String>? preview,
    Expression<DateTime>? dateUtc,
    Expression<bool>? isSeen,
    Expression<bool>? isFlagged,
    Expression<bool>? isAnswered,
    Expression<bool>? isDraft,
    Expression<bool>? isDeleted,
    Expression<bool>? hasAttachments,
    Expression<int>? sizeBytes,
    Expression<DateTime>? bodyFetchedAt,
    Expression<String>? labelsJson,
    Expression<bool>? isLocalOnly,
    Expression<int>? outboxState,
    Expression<String>? outboxError,
    Expression<int>? replyToMessageId,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (accountId != null) 'account_id': accountId,
      if (mailboxId != null) 'mailbox_id': mailboxId,
      if (uid != null) 'uid': uid,
      if (messageIdHeader != null) 'message_id_header': messageIdHeader,
      if (inReplyTo != null) 'in_reply_to': inReplyTo,
      if (referencesRaw != null) 'references_raw': referencesRaw,
      if (threadId != null) 'thread_id': threadId,
      if (fromName != null) 'from_name': fromName,
      if (fromEmail != null) 'from_email': fromEmail,
      if (toAddrJson != null) 'to_addr_json': toAddrJson,
      if (ccJson != null) 'cc_json': ccJson,
      if (bccJson != null) 'bcc_json': bccJson,
      if (subject != null) 'subject': subject,
      if (subjectNormalized != null) 'subject_normalized': subjectNormalized,
      if (preview != null) 'preview': preview,
      if (dateUtc != null) 'date_utc': dateUtc,
      if (isSeen != null) 'is_seen': isSeen,
      if (isFlagged != null) 'is_flagged': isFlagged,
      if (isAnswered != null) 'is_answered': isAnswered,
      if (isDraft != null) 'is_draft': isDraft,
      if (isDeleted != null) 'is_deleted': isDeleted,
      if (hasAttachments != null) 'has_attachments': hasAttachments,
      if (sizeBytes != null) 'size_bytes': sizeBytes,
      if (bodyFetchedAt != null) 'body_fetched_at': bodyFetchedAt,
      if (labelsJson != null) 'labels_json': labelsJson,
      if (isLocalOnly != null) 'is_local_only': isLocalOnly,
      if (outboxState != null) 'outbox_state': outboxState,
      if (outboxError != null) 'outbox_error': outboxError,
      if (replyToMessageId != null) 'reply_to_message_id': replyToMessageId,
    });
  }

  MessagesCompanion copyWith({
    Value<int>? id,
    Value<int>? accountId,
    Value<int>? mailboxId,
    Value<int?>? uid,
    Value<String?>? messageIdHeader,
    Value<String?>? inReplyTo,
    Value<String?>? referencesRaw,
    Value<String>? threadId,
    Value<String>? fromName,
    Value<String>? fromEmail,
    Value<String>? toAddrJson,
    Value<String>? ccJson,
    Value<String>? bccJson,
    Value<String>? subject,
    Value<String>? subjectNormalized,
    Value<String>? preview,
    Value<DateTime>? dateUtc,
    Value<bool>? isSeen,
    Value<bool>? isFlagged,
    Value<bool>? isAnswered,
    Value<bool>? isDraft,
    Value<bool>? isDeleted,
    Value<bool>? hasAttachments,
    Value<int>? sizeBytes,
    Value<DateTime?>? bodyFetchedAt,
    Value<String>? labelsJson,
    Value<bool>? isLocalOnly,
    Value<OutboxState>? outboxState,
    Value<String?>? outboxError,
    Value<int?>? replyToMessageId,
  }) {
    return MessagesCompanion(
      id: id ?? this.id,
      accountId: accountId ?? this.accountId,
      mailboxId: mailboxId ?? this.mailboxId,
      uid: uid ?? this.uid,
      messageIdHeader: messageIdHeader ?? this.messageIdHeader,
      inReplyTo: inReplyTo ?? this.inReplyTo,
      referencesRaw: referencesRaw ?? this.referencesRaw,
      threadId: threadId ?? this.threadId,
      fromName: fromName ?? this.fromName,
      fromEmail: fromEmail ?? this.fromEmail,
      toAddrJson: toAddrJson ?? this.toAddrJson,
      ccJson: ccJson ?? this.ccJson,
      bccJson: bccJson ?? this.bccJson,
      subject: subject ?? this.subject,
      subjectNormalized: subjectNormalized ?? this.subjectNormalized,
      preview: preview ?? this.preview,
      dateUtc: dateUtc ?? this.dateUtc,
      isSeen: isSeen ?? this.isSeen,
      isFlagged: isFlagged ?? this.isFlagged,
      isAnswered: isAnswered ?? this.isAnswered,
      isDraft: isDraft ?? this.isDraft,
      isDeleted: isDeleted ?? this.isDeleted,
      hasAttachments: hasAttachments ?? this.hasAttachments,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      bodyFetchedAt: bodyFetchedAt ?? this.bodyFetchedAt,
      labelsJson: labelsJson ?? this.labelsJson,
      isLocalOnly: isLocalOnly ?? this.isLocalOnly,
      outboxState: outboxState ?? this.outboxState,
      outboxError: outboxError ?? this.outboxError,
      replyToMessageId: replyToMessageId ?? this.replyToMessageId,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (accountId.present) {
      map['account_id'] = Variable<int>(accountId.value);
    }
    if (mailboxId.present) {
      map['mailbox_id'] = Variable<int>(mailboxId.value);
    }
    if (uid.present) {
      map['uid'] = Variable<int>(uid.value);
    }
    if (messageIdHeader.present) {
      map['message_id_header'] = Variable<String>(messageIdHeader.value);
    }
    if (inReplyTo.present) {
      map['in_reply_to'] = Variable<String>(inReplyTo.value);
    }
    if (referencesRaw.present) {
      map['references_raw'] = Variable<String>(referencesRaw.value);
    }
    if (threadId.present) {
      map['thread_id'] = Variable<String>(threadId.value);
    }
    if (fromName.present) {
      map['from_name'] = Variable<String>(fromName.value);
    }
    if (fromEmail.present) {
      map['from_email'] = Variable<String>(fromEmail.value);
    }
    if (toAddrJson.present) {
      map['to_addr_json'] = Variable<String>(toAddrJson.value);
    }
    if (ccJson.present) {
      map['cc_json'] = Variable<String>(ccJson.value);
    }
    if (bccJson.present) {
      map['bcc_json'] = Variable<String>(bccJson.value);
    }
    if (subject.present) {
      map['subject'] = Variable<String>(subject.value);
    }
    if (subjectNormalized.present) {
      map['subject_normalized'] = Variable<String>(subjectNormalized.value);
    }
    if (preview.present) {
      map['preview'] = Variable<String>(preview.value);
    }
    if (dateUtc.present) {
      map['date_utc'] = Variable<DateTime>(dateUtc.value);
    }
    if (isSeen.present) {
      map['is_seen'] = Variable<bool>(isSeen.value);
    }
    if (isFlagged.present) {
      map['is_flagged'] = Variable<bool>(isFlagged.value);
    }
    if (isAnswered.present) {
      map['is_answered'] = Variable<bool>(isAnswered.value);
    }
    if (isDraft.present) {
      map['is_draft'] = Variable<bool>(isDraft.value);
    }
    if (isDeleted.present) {
      map['is_deleted'] = Variable<bool>(isDeleted.value);
    }
    if (hasAttachments.present) {
      map['has_attachments'] = Variable<bool>(hasAttachments.value);
    }
    if (sizeBytes.present) {
      map['size_bytes'] = Variable<int>(sizeBytes.value);
    }
    if (bodyFetchedAt.present) {
      map['body_fetched_at'] = Variable<DateTime>(bodyFetchedAt.value);
    }
    if (labelsJson.present) {
      map['labels_json'] = Variable<String>(labelsJson.value);
    }
    if (isLocalOnly.present) {
      map['is_local_only'] = Variable<bool>(isLocalOnly.value);
    }
    if (outboxState.present) {
      map['outbox_state'] = Variable<int>(
        $MessagesTable.$converteroutboxState.toSql(outboxState.value),
      );
    }
    if (outboxError.present) {
      map['outbox_error'] = Variable<String>(outboxError.value);
    }
    if (replyToMessageId.present) {
      map['reply_to_message_id'] = Variable<int>(replyToMessageId.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MessagesCompanion(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('mailboxId: $mailboxId, ')
          ..write('uid: $uid, ')
          ..write('messageIdHeader: $messageIdHeader, ')
          ..write('inReplyTo: $inReplyTo, ')
          ..write('referencesRaw: $referencesRaw, ')
          ..write('threadId: $threadId, ')
          ..write('fromName: $fromName, ')
          ..write('fromEmail: $fromEmail, ')
          ..write('toAddrJson: $toAddrJson, ')
          ..write('ccJson: $ccJson, ')
          ..write('bccJson: $bccJson, ')
          ..write('subject: $subject, ')
          ..write('subjectNormalized: $subjectNormalized, ')
          ..write('preview: $preview, ')
          ..write('dateUtc: $dateUtc, ')
          ..write('isSeen: $isSeen, ')
          ..write('isFlagged: $isFlagged, ')
          ..write('isAnswered: $isAnswered, ')
          ..write('isDraft: $isDraft, ')
          ..write('isDeleted: $isDeleted, ')
          ..write('hasAttachments: $hasAttachments, ')
          ..write('sizeBytes: $sizeBytes, ')
          ..write('bodyFetchedAt: $bodyFetchedAt, ')
          ..write('labelsJson: $labelsJson, ')
          ..write('isLocalOnly: $isLocalOnly, ')
          ..write('outboxState: $outboxState, ')
          ..write('outboxError: $outboxError, ')
          ..write('replyToMessageId: $replyToMessageId')
          ..write(')'))
        .toString();
  }
}

class $MessageBodiesTable extends MessageBodies
    with TableInfo<$MessageBodiesTable, MessageBodyRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MessageBodiesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _messageIdMeta = const VerificationMeta(
    'messageId',
  );
  @override
  late final GeneratedColumn<int> messageId = GeneratedColumn<int>(
    'message_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES messages (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _plainTextMeta = const VerificationMeta(
    'plainText',
  );
  @override
  late final GeneratedColumn<String> plainText = GeneratedColumn<String>(
    'plain_text',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _htmlMeta = const VerificationMeta('html');
  @override
  late final GeneratedColumn<String> html = GeneratedColumn<String>(
    'html',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _fetchedAtMeta = const VerificationMeta(
    'fetchedAt',
  );
  @override
  late final GeneratedColumn<DateTime> fetchedAt = GeneratedColumn<DateTime>(
    'fetched_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
    defaultValue: currentDateAndTime,
  );
  @override
  List<GeneratedColumn> get $columns => [messageId, plainText, html, fetchedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'message_bodies';
  @override
  VerificationContext validateIntegrity(
    Insertable<MessageBodyRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('message_id')) {
      context.handle(
        _messageIdMeta,
        messageId.isAcceptableOrUnknown(data['message_id']!, _messageIdMeta),
      );
    }
    if (data.containsKey('plain_text')) {
      context.handle(
        _plainTextMeta,
        plainText.isAcceptableOrUnknown(data['plain_text']!, _plainTextMeta),
      );
    }
    if (data.containsKey('html')) {
      context.handle(
        _htmlMeta,
        html.isAcceptableOrUnknown(data['html']!, _htmlMeta),
      );
    }
    if (data.containsKey('fetched_at')) {
      context.handle(
        _fetchedAtMeta,
        fetchedAt.isAcceptableOrUnknown(data['fetched_at']!, _fetchedAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {messageId};
  @override
  MessageBodyRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MessageBodyRow(
      messageId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}message_id'],
      )!,
      plainText: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}plain_text'],
      ),
      html: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}html'],
      ),
      fetchedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}fetched_at'],
      )!,
    );
  }

  @override
  $MessageBodiesTable createAlias(String alias) {
    return $MessageBodiesTable(attachedDatabase, alias);
  }
}

class MessageBodyRow extends DataClass implements Insertable<MessageBodyRow> {
  final int messageId;
  final String? plainText;
  final String? html;
  final DateTime fetchedAt;
  const MessageBodyRow({
    required this.messageId,
    this.plainText,
    this.html,
    required this.fetchedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['message_id'] = Variable<int>(messageId);
    if (!nullToAbsent || plainText != null) {
      map['plain_text'] = Variable<String>(plainText);
    }
    if (!nullToAbsent || html != null) {
      map['html'] = Variable<String>(html);
    }
    map['fetched_at'] = Variable<DateTime>(fetchedAt);
    return map;
  }

  MessageBodiesCompanion toCompanion(bool nullToAbsent) {
    return MessageBodiesCompanion(
      messageId: Value(messageId),
      plainText: plainText == null && nullToAbsent
          ? const Value.absent()
          : Value(plainText),
      html: html == null && nullToAbsent ? const Value.absent() : Value(html),
      fetchedAt: Value(fetchedAt),
    );
  }

  factory MessageBodyRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MessageBodyRow(
      messageId: serializer.fromJson<int>(json['messageId']),
      plainText: serializer.fromJson<String?>(json['plainText']),
      html: serializer.fromJson<String?>(json['html']),
      fetchedAt: serializer.fromJson<DateTime>(json['fetchedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'messageId': serializer.toJson<int>(messageId),
      'plainText': serializer.toJson<String?>(plainText),
      'html': serializer.toJson<String?>(html),
      'fetchedAt': serializer.toJson<DateTime>(fetchedAt),
    };
  }

  MessageBodyRow copyWith({
    int? messageId,
    Value<String?> plainText = const Value.absent(),
    Value<String?> html = const Value.absent(),
    DateTime? fetchedAt,
  }) => MessageBodyRow(
    messageId: messageId ?? this.messageId,
    plainText: plainText.present ? plainText.value : this.plainText,
    html: html.present ? html.value : this.html,
    fetchedAt: fetchedAt ?? this.fetchedAt,
  );
  MessageBodyRow copyWithCompanion(MessageBodiesCompanion data) {
    return MessageBodyRow(
      messageId: data.messageId.present ? data.messageId.value : this.messageId,
      plainText: data.plainText.present ? data.plainText.value : this.plainText,
      html: data.html.present ? data.html.value : this.html,
      fetchedAt: data.fetchedAt.present ? data.fetchedAt.value : this.fetchedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MessageBodyRow(')
          ..write('messageId: $messageId, ')
          ..write('plainText: $plainText, ')
          ..write('html: $html, ')
          ..write('fetchedAt: $fetchedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(messageId, plainText, html, fetchedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MessageBodyRow &&
          other.messageId == this.messageId &&
          other.plainText == this.plainText &&
          other.html == this.html &&
          other.fetchedAt == this.fetchedAt);
}

class MessageBodiesCompanion extends UpdateCompanion<MessageBodyRow> {
  final Value<int> messageId;
  final Value<String?> plainText;
  final Value<String?> html;
  final Value<DateTime> fetchedAt;
  const MessageBodiesCompanion({
    this.messageId = const Value.absent(),
    this.plainText = const Value.absent(),
    this.html = const Value.absent(),
    this.fetchedAt = const Value.absent(),
  });
  MessageBodiesCompanion.insert({
    this.messageId = const Value.absent(),
    this.plainText = const Value.absent(),
    this.html = const Value.absent(),
    this.fetchedAt = const Value.absent(),
  });
  static Insertable<MessageBodyRow> custom({
    Expression<int>? messageId,
    Expression<String>? plainText,
    Expression<String>? html,
    Expression<DateTime>? fetchedAt,
  }) {
    return RawValuesInsertable({
      if (messageId != null) 'message_id': messageId,
      if (plainText != null) 'plain_text': plainText,
      if (html != null) 'html': html,
      if (fetchedAt != null) 'fetched_at': fetchedAt,
    });
  }

  MessageBodiesCompanion copyWith({
    Value<int>? messageId,
    Value<String?>? plainText,
    Value<String?>? html,
    Value<DateTime>? fetchedAt,
  }) {
    return MessageBodiesCompanion(
      messageId: messageId ?? this.messageId,
      plainText: plainText ?? this.plainText,
      html: html ?? this.html,
      fetchedAt: fetchedAt ?? this.fetchedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (messageId.present) {
      map['message_id'] = Variable<int>(messageId.value);
    }
    if (plainText.present) {
      map['plain_text'] = Variable<String>(plainText.value);
    }
    if (html.present) {
      map['html'] = Variable<String>(html.value);
    }
    if (fetchedAt.present) {
      map['fetched_at'] = Variable<DateTime>(fetchedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MessageBodiesCompanion(')
          ..write('messageId: $messageId, ')
          ..write('plainText: $plainText, ')
          ..write('html: $html, ')
          ..write('fetchedAt: $fetchedAt')
          ..write(')'))
        .toString();
  }
}

class $AttachmentsTable extends Attachments
    with TableInfo<$AttachmentsTable, AttachmentRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AttachmentsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _messageIdMeta = const VerificationMeta(
    'messageId',
  );
  @override
  late final GeneratedColumn<int> messageId = GeneratedColumn<int>(
    'message_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES messages (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _partIdMeta = const VerificationMeta('partId');
  @override
  late final GeneratedColumn<String> partId = GeneratedColumn<String>(
    'part_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _fileNameMeta = const VerificationMeta(
    'fileName',
  );
  @override
  late final GeneratedColumn<String> fileName = GeneratedColumn<String>(
    'file_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('dosya'),
  );
  static const VerificationMeta _mimeTypeMeta = const VerificationMeta(
    'mimeType',
  );
  @override
  late final GeneratedColumn<String> mimeType = GeneratedColumn<String>(
    'mime_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('application/octet-stream'),
  );
  static const VerificationMeta _sizeBytesMeta = const VerificationMeta(
    'sizeBytes',
  );
  @override
  late final GeneratedColumn<int> sizeBytes = GeneratedColumn<int>(
    'size_bytes',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _contentIdMeta = const VerificationMeta(
    'contentId',
  );
  @override
  late final GeneratedColumn<String> contentId = GeneratedColumn<String>(
    'content_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _isInlineMeta = const VerificationMeta(
    'isInline',
  );
  @override
  late final GeneratedColumn<bool> isInline = GeneratedColumn<bool>(
    'is_inline',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_inline" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _localPathMeta = const VerificationMeta(
    'localPath',
  );
  @override
  late final GeneratedColumn<String> localPath = GeneratedColumn<String>(
    'local_path',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _isOutgoingMeta = const VerificationMeta(
    'isOutgoing',
  );
  @override
  late final GeneratedColumn<bool> isOutgoing = GeneratedColumn<bool>(
    'is_outgoing',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_outgoing" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    messageId,
    partId,
    fileName,
    mimeType,
    sizeBytes,
    contentId,
    isInline,
    localPath,
    isOutgoing,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'attachments';
  @override
  VerificationContext validateIntegrity(
    Insertable<AttachmentRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('message_id')) {
      context.handle(
        _messageIdMeta,
        messageId.isAcceptableOrUnknown(data['message_id']!, _messageIdMeta),
      );
    } else if (isInserting) {
      context.missing(_messageIdMeta);
    }
    if (data.containsKey('part_id')) {
      context.handle(
        _partIdMeta,
        partId.isAcceptableOrUnknown(data['part_id']!, _partIdMeta),
      );
    }
    if (data.containsKey('file_name')) {
      context.handle(
        _fileNameMeta,
        fileName.isAcceptableOrUnknown(data['file_name']!, _fileNameMeta),
      );
    }
    if (data.containsKey('mime_type')) {
      context.handle(
        _mimeTypeMeta,
        mimeType.isAcceptableOrUnknown(data['mime_type']!, _mimeTypeMeta),
      );
    }
    if (data.containsKey('size_bytes')) {
      context.handle(
        _sizeBytesMeta,
        sizeBytes.isAcceptableOrUnknown(data['size_bytes']!, _sizeBytesMeta),
      );
    }
    if (data.containsKey('content_id')) {
      context.handle(
        _contentIdMeta,
        contentId.isAcceptableOrUnknown(data['content_id']!, _contentIdMeta),
      );
    }
    if (data.containsKey('is_inline')) {
      context.handle(
        _isInlineMeta,
        isInline.isAcceptableOrUnknown(data['is_inline']!, _isInlineMeta),
      );
    }
    if (data.containsKey('local_path')) {
      context.handle(
        _localPathMeta,
        localPath.isAcceptableOrUnknown(data['local_path']!, _localPathMeta),
      );
    }
    if (data.containsKey('is_outgoing')) {
      context.handle(
        _isOutgoingMeta,
        isOutgoing.isAcceptableOrUnknown(data['is_outgoing']!, _isOutgoingMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  AttachmentRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AttachmentRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      messageId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}message_id'],
      )!,
      partId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}part_id'],
      )!,
      fileName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}file_name'],
      )!,
      mimeType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}mime_type'],
      )!,
      sizeBytes: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}size_bytes'],
      )!,
      contentId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}content_id'],
      ),
      isInline: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_inline'],
      )!,
      localPath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}local_path'],
      ),
      isOutgoing: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_outgoing'],
      )!,
    );
  }

  @override
  $AttachmentsTable createAlias(String alias) {
    return $AttachmentsTable(attachedDatabase, alias);
  }
}

class AttachmentRow extends DataClass implements Insertable<AttachmentRow> {
  final int id;
  final int messageId;

  /// IMAP BODYSTRUCTURE parça yolu (ör. `2.1`).
  final String partId;
  final String fileName;
  final String mimeType;
  final int sizeBytes;
  final String? contentId;
  final bool isInline;

  /// İndirildiyse cihazdaki yol.
  final String? localPath;

  /// Gönderilecek yerel dosya (compose ekranından eklenen).
  final bool isOutgoing;
  const AttachmentRow({
    required this.id,
    required this.messageId,
    required this.partId,
    required this.fileName,
    required this.mimeType,
    required this.sizeBytes,
    this.contentId,
    required this.isInline,
    this.localPath,
    required this.isOutgoing,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['message_id'] = Variable<int>(messageId);
    map['part_id'] = Variable<String>(partId);
    map['file_name'] = Variable<String>(fileName);
    map['mime_type'] = Variable<String>(mimeType);
    map['size_bytes'] = Variable<int>(sizeBytes);
    if (!nullToAbsent || contentId != null) {
      map['content_id'] = Variable<String>(contentId);
    }
    map['is_inline'] = Variable<bool>(isInline);
    if (!nullToAbsent || localPath != null) {
      map['local_path'] = Variable<String>(localPath);
    }
    map['is_outgoing'] = Variable<bool>(isOutgoing);
    return map;
  }

  AttachmentsCompanion toCompanion(bool nullToAbsent) {
    return AttachmentsCompanion(
      id: Value(id),
      messageId: Value(messageId),
      partId: Value(partId),
      fileName: Value(fileName),
      mimeType: Value(mimeType),
      sizeBytes: Value(sizeBytes),
      contentId: contentId == null && nullToAbsent
          ? const Value.absent()
          : Value(contentId),
      isInline: Value(isInline),
      localPath: localPath == null && nullToAbsent
          ? const Value.absent()
          : Value(localPath),
      isOutgoing: Value(isOutgoing),
    );
  }

  factory AttachmentRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AttachmentRow(
      id: serializer.fromJson<int>(json['id']),
      messageId: serializer.fromJson<int>(json['messageId']),
      partId: serializer.fromJson<String>(json['partId']),
      fileName: serializer.fromJson<String>(json['fileName']),
      mimeType: serializer.fromJson<String>(json['mimeType']),
      sizeBytes: serializer.fromJson<int>(json['sizeBytes']),
      contentId: serializer.fromJson<String?>(json['contentId']),
      isInline: serializer.fromJson<bool>(json['isInline']),
      localPath: serializer.fromJson<String?>(json['localPath']),
      isOutgoing: serializer.fromJson<bool>(json['isOutgoing']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'messageId': serializer.toJson<int>(messageId),
      'partId': serializer.toJson<String>(partId),
      'fileName': serializer.toJson<String>(fileName),
      'mimeType': serializer.toJson<String>(mimeType),
      'sizeBytes': serializer.toJson<int>(sizeBytes),
      'contentId': serializer.toJson<String?>(contentId),
      'isInline': serializer.toJson<bool>(isInline),
      'localPath': serializer.toJson<String?>(localPath),
      'isOutgoing': serializer.toJson<bool>(isOutgoing),
    };
  }

  AttachmentRow copyWith({
    int? id,
    int? messageId,
    String? partId,
    String? fileName,
    String? mimeType,
    int? sizeBytes,
    Value<String?> contentId = const Value.absent(),
    bool? isInline,
    Value<String?> localPath = const Value.absent(),
    bool? isOutgoing,
  }) => AttachmentRow(
    id: id ?? this.id,
    messageId: messageId ?? this.messageId,
    partId: partId ?? this.partId,
    fileName: fileName ?? this.fileName,
    mimeType: mimeType ?? this.mimeType,
    sizeBytes: sizeBytes ?? this.sizeBytes,
    contentId: contentId.present ? contentId.value : this.contentId,
    isInline: isInline ?? this.isInline,
    localPath: localPath.present ? localPath.value : this.localPath,
    isOutgoing: isOutgoing ?? this.isOutgoing,
  );
  AttachmentRow copyWithCompanion(AttachmentsCompanion data) {
    return AttachmentRow(
      id: data.id.present ? data.id.value : this.id,
      messageId: data.messageId.present ? data.messageId.value : this.messageId,
      partId: data.partId.present ? data.partId.value : this.partId,
      fileName: data.fileName.present ? data.fileName.value : this.fileName,
      mimeType: data.mimeType.present ? data.mimeType.value : this.mimeType,
      sizeBytes: data.sizeBytes.present ? data.sizeBytes.value : this.sizeBytes,
      contentId: data.contentId.present ? data.contentId.value : this.contentId,
      isInline: data.isInline.present ? data.isInline.value : this.isInline,
      localPath: data.localPath.present ? data.localPath.value : this.localPath,
      isOutgoing: data.isOutgoing.present
          ? data.isOutgoing.value
          : this.isOutgoing,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AttachmentRow(')
          ..write('id: $id, ')
          ..write('messageId: $messageId, ')
          ..write('partId: $partId, ')
          ..write('fileName: $fileName, ')
          ..write('mimeType: $mimeType, ')
          ..write('sizeBytes: $sizeBytes, ')
          ..write('contentId: $contentId, ')
          ..write('isInline: $isInline, ')
          ..write('localPath: $localPath, ')
          ..write('isOutgoing: $isOutgoing')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    messageId,
    partId,
    fileName,
    mimeType,
    sizeBytes,
    contentId,
    isInline,
    localPath,
    isOutgoing,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AttachmentRow &&
          other.id == this.id &&
          other.messageId == this.messageId &&
          other.partId == this.partId &&
          other.fileName == this.fileName &&
          other.mimeType == this.mimeType &&
          other.sizeBytes == this.sizeBytes &&
          other.contentId == this.contentId &&
          other.isInline == this.isInline &&
          other.localPath == this.localPath &&
          other.isOutgoing == this.isOutgoing);
}

class AttachmentsCompanion extends UpdateCompanion<AttachmentRow> {
  final Value<int> id;
  final Value<int> messageId;
  final Value<String> partId;
  final Value<String> fileName;
  final Value<String> mimeType;
  final Value<int> sizeBytes;
  final Value<String?> contentId;
  final Value<bool> isInline;
  final Value<String?> localPath;
  final Value<bool> isOutgoing;
  const AttachmentsCompanion({
    this.id = const Value.absent(),
    this.messageId = const Value.absent(),
    this.partId = const Value.absent(),
    this.fileName = const Value.absent(),
    this.mimeType = const Value.absent(),
    this.sizeBytes = const Value.absent(),
    this.contentId = const Value.absent(),
    this.isInline = const Value.absent(),
    this.localPath = const Value.absent(),
    this.isOutgoing = const Value.absent(),
  });
  AttachmentsCompanion.insert({
    this.id = const Value.absent(),
    required int messageId,
    this.partId = const Value.absent(),
    this.fileName = const Value.absent(),
    this.mimeType = const Value.absent(),
    this.sizeBytes = const Value.absent(),
    this.contentId = const Value.absent(),
    this.isInline = const Value.absent(),
    this.localPath = const Value.absent(),
    this.isOutgoing = const Value.absent(),
  }) : messageId = Value(messageId);
  static Insertable<AttachmentRow> custom({
    Expression<int>? id,
    Expression<int>? messageId,
    Expression<String>? partId,
    Expression<String>? fileName,
    Expression<String>? mimeType,
    Expression<int>? sizeBytes,
    Expression<String>? contentId,
    Expression<bool>? isInline,
    Expression<String>? localPath,
    Expression<bool>? isOutgoing,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (messageId != null) 'message_id': messageId,
      if (partId != null) 'part_id': partId,
      if (fileName != null) 'file_name': fileName,
      if (mimeType != null) 'mime_type': mimeType,
      if (sizeBytes != null) 'size_bytes': sizeBytes,
      if (contentId != null) 'content_id': contentId,
      if (isInline != null) 'is_inline': isInline,
      if (localPath != null) 'local_path': localPath,
      if (isOutgoing != null) 'is_outgoing': isOutgoing,
    });
  }

  AttachmentsCompanion copyWith({
    Value<int>? id,
    Value<int>? messageId,
    Value<String>? partId,
    Value<String>? fileName,
    Value<String>? mimeType,
    Value<int>? sizeBytes,
    Value<String?>? contentId,
    Value<bool>? isInline,
    Value<String?>? localPath,
    Value<bool>? isOutgoing,
  }) {
    return AttachmentsCompanion(
      id: id ?? this.id,
      messageId: messageId ?? this.messageId,
      partId: partId ?? this.partId,
      fileName: fileName ?? this.fileName,
      mimeType: mimeType ?? this.mimeType,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      contentId: contentId ?? this.contentId,
      isInline: isInline ?? this.isInline,
      localPath: localPath ?? this.localPath,
      isOutgoing: isOutgoing ?? this.isOutgoing,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (messageId.present) {
      map['message_id'] = Variable<int>(messageId.value);
    }
    if (partId.present) {
      map['part_id'] = Variable<String>(partId.value);
    }
    if (fileName.present) {
      map['file_name'] = Variable<String>(fileName.value);
    }
    if (mimeType.present) {
      map['mime_type'] = Variable<String>(mimeType.value);
    }
    if (sizeBytes.present) {
      map['size_bytes'] = Variable<int>(sizeBytes.value);
    }
    if (contentId.present) {
      map['content_id'] = Variable<String>(contentId.value);
    }
    if (isInline.present) {
      map['is_inline'] = Variable<bool>(isInline.value);
    }
    if (localPath.present) {
      map['local_path'] = Variable<String>(localPath.value);
    }
    if (isOutgoing.present) {
      map['is_outgoing'] = Variable<bool>(isOutgoing.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AttachmentsCompanion(')
          ..write('id: $id, ')
          ..write('messageId: $messageId, ')
          ..write('partId: $partId, ')
          ..write('fileName: $fileName, ')
          ..write('mimeType: $mimeType, ')
          ..write('sizeBytes: $sizeBytes, ')
          ..write('contentId: $contentId, ')
          ..write('isInline: $isInline, ')
          ..write('localPath: $localPath, ')
          ..write('isOutgoing: $isOutgoing')
          ..write(')'))
        .toString();
  }
}

class $LabelsTable extends Labels with TableInfo<$LabelsTable, LabelRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LabelsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _accountIdMeta = const VerificationMeta(
    'accountId',
  );
  @override
  late final GeneratedColumn<int> accountId = GeneratedColumn<int>(
    'account_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES accounts (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _toneIndexMeta = const VerificationMeta(
    'toneIndex',
  );
  @override
  late final GeneratedColumn<int> toneIndex = GeneratedColumn<int>(
    'tone_index',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _imapKeywordMeta = const VerificationMeta(
    'imapKeyword',
  );
  @override
  late final GeneratedColumn<String> imapKeyword = GeneratedColumn<String>(
    'imap_keyword',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    accountId,
    name,
    toneIndex,
    imapKeyword,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'labels';
  @override
  VerificationContext validateIntegrity(
    Insertable<LabelRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('account_id')) {
      context.handle(
        _accountIdMeta,
        accountId.isAcceptableOrUnknown(data['account_id']!, _accountIdMeta),
      );
    } else if (isInserting) {
      context.missing(_accountIdMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('tone_index')) {
      context.handle(
        _toneIndexMeta,
        toneIndex.isAcceptableOrUnknown(data['tone_index']!, _toneIndexMeta),
      );
    }
    if (data.containsKey('imap_keyword')) {
      context.handle(
        _imapKeywordMeta,
        imapKeyword.isAcceptableOrUnknown(
          data['imap_keyword']!,
          _imapKeywordMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  List<Set<GeneratedColumn>> get uniqueKeys => [
    {accountId, name},
  ];
  @override
  LabelRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LabelRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}account_id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      toneIndex: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}tone_index'],
      )!,
      imapKeyword: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}imap_keyword'],
      ),
    );
  }

  @override
  $LabelsTable createAlias(String alias) {
    return $LabelsTable(attachedDatabase, alias);
  }
}

class LabelRow extends DataClass implements Insertable<LabelRow> {
  final int id;
  final int accountId;
  final String name;
  final int toneIndex;

  /// Sunucuya yazılıyorsa IMAP anahtar kelimesi.
  final String? imapKeyword;
  const LabelRow({
    required this.id,
    required this.accountId,
    required this.name,
    required this.toneIndex,
    this.imapKeyword,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['account_id'] = Variable<int>(accountId);
    map['name'] = Variable<String>(name);
    map['tone_index'] = Variable<int>(toneIndex);
    if (!nullToAbsent || imapKeyword != null) {
      map['imap_keyword'] = Variable<String>(imapKeyword);
    }
    return map;
  }

  LabelsCompanion toCompanion(bool nullToAbsent) {
    return LabelsCompanion(
      id: Value(id),
      accountId: Value(accountId),
      name: Value(name),
      toneIndex: Value(toneIndex),
      imapKeyword: imapKeyword == null && nullToAbsent
          ? const Value.absent()
          : Value(imapKeyword),
    );
  }

  factory LabelRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LabelRow(
      id: serializer.fromJson<int>(json['id']),
      accountId: serializer.fromJson<int>(json['accountId']),
      name: serializer.fromJson<String>(json['name']),
      toneIndex: serializer.fromJson<int>(json['toneIndex']),
      imapKeyword: serializer.fromJson<String?>(json['imapKeyword']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'accountId': serializer.toJson<int>(accountId),
      'name': serializer.toJson<String>(name),
      'toneIndex': serializer.toJson<int>(toneIndex),
      'imapKeyword': serializer.toJson<String?>(imapKeyword),
    };
  }

  LabelRow copyWith({
    int? id,
    int? accountId,
    String? name,
    int? toneIndex,
    Value<String?> imapKeyword = const Value.absent(),
  }) => LabelRow(
    id: id ?? this.id,
    accountId: accountId ?? this.accountId,
    name: name ?? this.name,
    toneIndex: toneIndex ?? this.toneIndex,
    imapKeyword: imapKeyword.present ? imapKeyword.value : this.imapKeyword,
  );
  LabelRow copyWithCompanion(LabelsCompanion data) {
    return LabelRow(
      id: data.id.present ? data.id.value : this.id,
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      name: data.name.present ? data.name.value : this.name,
      toneIndex: data.toneIndex.present ? data.toneIndex.value : this.toneIndex,
      imapKeyword: data.imapKeyword.present
          ? data.imapKeyword.value
          : this.imapKeyword,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LabelRow(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('name: $name, ')
          ..write('toneIndex: $toneIndex, ')
          ..write('imapKeyword: $imapKeyword')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, accountId, name, toneIndex, imapKeyword);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LabelRow &&
          other.id == this.id &&
          other.accountId == this.accountId &&
          other.name == this.name &&
          other.toneIndex == this.toneIndex &&
          other.imapKeyword == this.imapKeyword);
}

class LabelsCompanion extends UpdateCompanion<LabelRow> {
  final Value<int> id;
  final Value<int> accountId;
  final Value<String> name;
  final Value<int> toneIndex;
  final Value<String?> imapKeyword;
  const LabelsCompanion({
    this.id = const Value.absent(),
    this.accountId = const Value.absent(),
    this.name = const Value.absent(),
    this.toneIndex = const Value.absent(),
    this.imapKeyword = const Value.absent(),
  });
  LabelsCompanion.insert({
    this.id = const Value.absent(),
    required int accountId,
    required String name,
    this.toneIndex = const Value.absent(),
    this.imapKeyword = const Value.absent(),
  }) : accountId = Value(accountId),
       name = Value(name);
  static Insertable<LabelRow> custom({
    Expression<int>? id,
    Expression<int>? accountId,
    Expression<String>? name,
    Expression<int>? toneIndex,
    Expression<String>? imapKeyword,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (accountId != null) 'account_id': accountId,
      if (name != null) 'name': name,
      if (toneIndex != null) 'tone_index': toneIndex,
      if (imapKeyword != null) 'imap_keyword': imapKeyword,
    });
  }

  LabelsCompanion copyWith({
    Value<int>? id,
    Value<int>? accountId,
    Value<String>? name,
    Value<int>? toneIndex,
    Value<String?>? imapKeyword,
  }) {
    return LabelsCompanion(
      id: id ?? this.id,
      accountId: accountId ?? this.accountId,
      name: name ?? this.name,
      toneIndex: toneIndex ?? this.toneIndex,
      imapKeyword: imapKeyword ?? this.imapKeyword,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (accountId.present) {
      map['account_id'] = Variable<int>(accountId.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (toneIndex.present) {
      map['tone_index'] = Variable<int>(toneIndex.value);
    }
    if (imapKeyword.present) {
      map['imap_keyword'] = Variable<String>(imapKeyword.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LabelsCompanion(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('name: $name, ')
          ..write('toneIndex: $toneIndex, ')
          ..write('imapKeyword: $imapKeyword')
          ..write(')'))
        .toString();
  }
}

class $PendingOperationsTable extends PendingOperations
    with TableInfo<$PendingOperationsTable, PendingOperationRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PendingOperationsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _accountIdMeta = const VerificationMeta(
    'accountId',
  );
  @override
  late final GeneratedColumn<int> accountId = GeneratedColumn<int>(
    'account_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES accounts (id) ON DELETE CASCADE',
    ),
  );
  @override
  late final GeneratedColumnWithTypeConverter<PendingOpType, int> type =
      GeneratedColumn<int>(
        'type',
        aliasedName,
        false,
        type: DriftSqlType.int,
        requiredDuringInsert: true,
      ).withConverter<PendingOpType>($PendingOperationsTable.$convertertype);
  static const VerificationMeta _payloadJsonMeta = const VerificationMeta(
    'payloadJson',
  );
  @override
  late final GeneratedColumn<String> payloadJson = GeneratedColumn<String>(
    'payload_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('{}'),
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
    defaultValue: currentDateAndTime,
  );
  static const VerificationMeta _attemptCountMeta = const VerificationMeta(
    'attemptCount',
  );
  @override
  late final GeneratedColumn<int> attemptCount = GeneratedColumn<int>(
    'attempt_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _nextAttemptAtMeta = const VerificationMeta(
    'nextAttemptAt',
  );
  @override
  late final GeneratedColumn<DateTime> nextAttemptAt =
      GeneratedColumn<DateTime>(
        'next_attempt_at',
        aliasedName,
        true,
        type: DriftSqlType.dateTime,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _lastErrorMeta = const VerificationMeta(
    'lastError',
  );
  @override
  late final GeneratedColumn<String> lastError = GeneratedColumn<String>(
    'last_error',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  late final GeneratedColumnWithTypeConverter<PendingOpStatus, int> status =
      GeneratedColumn<int>(
        'status',
        aliasedName,
        false,
        type: DriftSqlType.int,
        requiredDuringInsert: false,
        defaultValue: const Constant(0),
      ).withConverter<PendingOpStatus>(
        $PendingOperationsTable.$converterstatus,
      );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    accountId,
    type,
    payloadJson,
    createdAt,
    attemptCount,
    nextAttemptAt,
    lastError,
    status,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'pending_operations';
  @override
  VerificationContext validateIntegrity(
    Insertable<PendingOperationRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('account_id')) {
      context.handle(
        _accountIdMeta,
        accountId.isAcceptableOrUnknown(data['account_id']!, _accountIdMeta),
      );
    } else if (isInserting) {
      context.missing(_accountIdMeta);
    }
    if (data.containsKey('payload_json')) {
      context.handle(
        _payloadJsonMeta,
        payloadJson.isAcceptableOrUnknown(
          data['payload_json']!,
          _payloadJsonMeta,
        ),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    }
    if (data.containsKey('attempt_count')) {
      context.handle(
        _attemptCountMeta,
        attemptCount.isAcceptableOrUnknown(
          data['attempt_count']!,
          _attemptCountMeta,
        ),
      );
    }
    if (data.containsKey('next_attempt_at')) {
      context.handle(
        _nextAttemptAtMeta,
        nextAttemptAt.isAcceptableOrUnknown(
          data['next_attempt_at']!,
          _nextAttemptAtMeta,
        ),
      );
    }
    if (data.containsKey('last_error')) {
      context.handle(
        _lastErrorMeta,
        lastError.isAcceptableOrUnknown(data['last_error']!, _lastErrorMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  PendingOperationRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PendingOperationRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}account_id'],
      )!,
      type: $PendingOperationsTable.$convertertype.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.int,
          data['${effectivePrefix}type'],
        )!,
      ),
      payloadJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}payload_json'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
      attemptCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}attempt_count'],
      )!,
      nextAttemptAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}next_attempt_at'],
      ),
      lastError: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}last_error'],
      ),
      status: $PendingOperationsTable.$converterstatus.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.int,
          data['${effectivePrefix}status'],
        )!,
      ),
    );
  }

  @override
  $PendingOperationsTable createAlias(String alias) {
    return $PendingOperationsTable(attachedDatabase, alias);
  }

  static JsonTypeConverter2<PendingOpType, int, int> $convertertype =
      const EnumIndexConverter<PendingOpType>(PendingOpType.values);
  static JsonTypeConverter2<PendingOpStatus, int, int> $converterstatus =
      const EnumIndexConverter<PendingOpStatus>(PendingOpStatus.values);
}

class PendingOperationRow extends DataClass
    implements Insertable<PendingOperationRow> {
  final int id;
  final int accountId;
  final PendingOpType type;
  final String payloadJson;
  final DateTime createdAt;
  final int attemptCount;
  final DateTime? nextAttemptAt;
  final String? lastError;
  final PendingOpStatus status;
  const PendingOperationRow({
    required this.id,
    required this.accountId,
    required this.type,
    required this.payloadJson,
    required this.createdAt,
    required this.attemptCount,
    this.nextAttemptAt,
    this.lastError,
    required this.status,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['account_id'] = Variable<int>(accountId);
    {
      map['type'] = Variable<int>(
        $PendingOperationsTable.$convertertype.toSql(type),
      );
    }
    map['payload_json'] = Variable<String>(payloadJson);
    map['created_at'] = Variable<DateTime>(createdAt);
    map['attempt_count'] = Variable<int>(attemptCount);
    if (!nullToAbsent || nextAttemptAt != null) {
      map['next_attempt_at'] = Variable<DateTime>(nextAttemptAt);
    }
    if (!nullToAbsent || lastError != null) {
      map['last_error'] = Variable<String>(lastError);
    }
    {
      map['status'] = Variable<int>(
        $PendingOperationsTable.$converterstatus.toSql(status),
      );
    }
    return map;
  }

  PendingOperationsCompanion toCompanion(bool nullToAbsent) {
    return PendingOperationsCompanion(
      id: Value(id),
      accountId: Value(accountId),
      type: Value(type),
      payloadJson: Value(payloadJson),
      createdAt: Value(createdAt),
      attemptCount: Value(attemptCount),
      nextAttemptAt: nextAttemptAt == null && nullToAbsent
          ? const Value.absent()
          : Value(nextAttemptAt),
      lastError: lastError == null && nullToAbsent
          ? const Value.absent()
          : Value(lastError),
      status: Value(status),
    );
  }

  factory PendingOperationRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PendingOperationRow(
      id: serializer.fromJson<int>(json['id']),
      accountId: serializer.fromJson<int>(json['accountId']),
      type: $PendingOperationsTable.$convertertype.fromJson(
        serializer.fromJson<int>(json['type']),
      ),
      payloadJson: serializer.fromJson<String>(json['payloadJson']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      attemptCount: serializer.fromJson<int>(json['attemptCount']),
      nextAttemptAt: serializer.fromJson<DateTime?>(json['nextAttemptAt']),
      lastError: serializer.fromJson<String?>(json['lastError']),
      status: $PendingOperationsTable.$converterstatus.fromJson(
        serializer.fromJson<int>(json['status']),
      ),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'accountId': serializer.toJson<int>(accountId),
      'type': serializer.toJson<int>(
        $PendingOperationsTable.$convertertype.toJson(type),
      ),
      'payloadJson': serializer.toJson<String>(payloadJson),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'attemptCount': serializer.toJson<int>(attemptCount),
      'nextAttemptAt': serializer.toJson<DateTime?>(nextAttemptAt),
      'lastError': serializer.toJson<String?>(lastError),
      'status': serializer.toJson<int>(
        $PendingOperationsTable.$converterstatus.toJson(status),
      ),
    };
  }

  PendingOperationRow copyWith({
    int? id,
    int? accountId,
    PendingOpType? type,
    String? payloadJson,
    DateTime? createdAt,
    int? attemptCount,
    Value<DateTime?> nextAttemptAt = const Value.absent(),
    Value<String?> lastError = const Value.absent(),
    PendingOpStatus? status,
  }) => PendingOperationRow(
    id: id ?? this.id,
    accountId: accountId ?? this.accountId,
    type: type ?? this.type,
    payloadJson: payloadJson ?? this.payloadJson,
    createdAt: createdAt ?? this.createdAt,
    attemptCount: attemptCount ?? this.attemptCount,
    nextAttemptAt: nextAttemptAt.present
        ? nextAttemptAt.value
        : this.nextAttemptAt,
    lastError: lastError.present ? lastError.value : this.lastError,
    status: status ?? this.status,
  );
  PendingOperationRow copyWithCompanion(PendingOperationsCompanion data) {
    return PendingOperationRow(
      id: data.id.present ? data.id.value : this.id,
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      type: data.type.present ? data.type.value : this.type,
      payloadJson: data.payloadJson.present
          ? data.payloadJson.value
          : this.payloadJson,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      attemptCount: data.attemptCount.present
          ? data.attemptCount.value
          : this.attemptCount,
      nextAttemptAt: data.nextAttemptAt.present
          ? data.nextAttemptAt.value
          : this.nextAttemptAt,
      lastError: data.lastError.present ? data.lastError.value : this.lastError,
      status: data.status.present ? data.status.value : this.status,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PendingOperationRow(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('type: $type, ')
          ..write('payloadJson: $payloadJson, ')
          ..write('createdAt: $createdAt, ')
          ..write('attemptCount: $attemptCount, ')
          ..write('nextAttemptAt: $nextAttemptAt, ')
          ..write('lastError: $lastError, ')
          ..write('status: $status')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    accountId,
    type,
    payloadJson,
    createdAt,
    attemptCount,
    nextAttemptAt,
    lastError,
    status,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PendingOperationRow &&
          other.id == this.id &&
          other.accountId == this.accountId &&
          other.type == this.type &&
          other.payloadJson == this.payloadJson &&
          other.createdAt == this.createdAt &&
          other.attemptCount == this.attemptCount &&
          other.nextAttemptAt == this.nextAttemptAt &&
          other.lastError == this.lastError &&
          other.status == this.status);
}

class PendingOperationsCompanion extends UpdateCompanion<PendingOperationRow> {
  final Value<int> id;
  final Value<int> accountId;
  final Value<PendingOpType> type;
  final Value<String> payloadJson;
  final Value<DateTime> createdAt;
  final Value<int> attemptCount;
  final Value<DateTime?> nextAttemptAt;
  final Value<String?> lastError;
  final Value<PendingOpStatus> status;
  const PendingOperationsCompanion({
    this.id = const Value.absent(),
    this.accountId = const Value.absent(),
    this.type = const Value.absent(),
    this.payloadJson = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.attemptCount = const Value.absent(),
    this.nextAttemptAt = const Value.absent(),
    this.lastError = const Value.absent(),
    this.status = const Value.absent(),
  });
  PendingOperationsCompanion.insert({
    this.id = const Value.absent(),
    required int accountId,
    required PendingOpType type,
    this.payloadJson = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.attemptCount = const Value.absent(),
    this.nextAttemptAt = const Value.absent(),
    this.lastError = const Value.absent(),
    this.status = const Value.absent(),
  }) : accountId = Value(accountId),
       type = Value(type);
  static Insertable<PendingOperationRow> custom({
    Expression<int>? id,
    Expression<int>? accountId,
    Expression<int>? type,
    Expression<String>? payloadJson,
    Expression<DateTime>? createdAt,
    Expression<int>? attemptCount,
    Expression<DateTime>? nextAttemptAt,
    Expression<String>? lastError,
    Expression<int>? status,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (accountId != null) 'account_id': accountId,
      if (type != null) 'type': type,
      if (payloadJson != null) 'payload_json': payloadJson,
      if (createdAt != null) 'created_at': createdAt,
      if (attemptCount != null) 'attempt_count': attemptCount,
      if (nextAttemptAt != null) 'next_attempt_at': nextAttemptAt,
      if (lastError != null) 'last_error': lastError,
      if (status != null) 'status': status,
    });
  }

  PendingOperationsCompanion copyWith({
    Value<int>? id,
    Value<int>? accountId,
    Value<PendingOpType>? type,
    Value<String>? payloadJson,
    Value<DateTime>? createdAt,
    Value<int>? attemptCount,
    Value<DateTime?>? nextAttemptAt,
    Value<String?>? lastError,
    Value<PendingOpStatus>? status,
  }) {
    return PendingOperationsCompanion(
      id: id ?? this.id,
      accountId: accountId ?? this.accountId,
      type: type ?? this.type,
      payloadJson: payloadJson ?? this.payloadJson,
      createdAt: createdAt ?? this.createdAt,
      attemptCount: attemptCount ?? this.attemptCount,
      nextAttemptAt: nextAttemptAt ?? this.nextAttemptAt,
      lastError: lastError ?? this.lastError,
      status: status ?? this.status,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (accountId.present) {
      map['account_id'] = Variable<int>(accountId.value);
    }
    if (type.present) {
      map['type'] = Variable<int>(
        $PendingOperationsTable.$convertertype.toSql(type.value),
      );
    }
    if (payloadJson.present) {
      map['payload_json'] = Variable<String>(payloadJson.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (attemptCount.present) {
      map['attempt_count'] = Variable<int>(attemptCount.value);
    }
    if (nextAttemptAt.present) {
      map['next_attempt_at'] = Variable<DateTime>(nextAttemptAt.value);
    }
    if (lastError.present) {
      map['last_error'] = Variable<String>(lastError.value);
    }
    if (status.present) {
      map['status'] = Variable<int>(
        $PendingOperationsTable.$converterstatus.toSql(status.value),
      );
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PendingOperationsCompanion(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('type: $type, ')
          ..write('payloadJson: $payloadJson, ')
          ..write('createdAt: $createdAt, ')
          ..write('attemptCount: $attemptCount, ')
          ..write('nextAttemptAt: $nextAttemptAt, ')
          ..write('lastError: $lastError, ')
          ..write('status: $status')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $AccountsTable accounts = $AccountsTable(this);
  late final $MailboxesTable mailboxes = $MailboxesTable(this);
  late final $MessagesTable messages = $MessagesTable(this);
  late final $MessageBodiesTable messageBodies = $MessageBodiesTable(this);
  late final $AttachmentsTable attachments = $AttachmentsTable(this);
  late final $LabelsTable labels = $LabelsTable(this);
  late final $PendingOperationsTable pendingOperations =
      $PendingOperationsTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    accounts,
    mailboxes,
    messages,
    messageBodies,
    attachments,
    labels,
    pendingOperations,
  ];
  @override
  StreamQueryUpdateRules get streamUpdateRules => const StreamQueryUpdateRules([
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'accounts',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('mailboxes', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'accounts',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('messages', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'mailboxes',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('messages', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'messages',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('message_bodies', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'messages',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('attachments', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'accounts',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('labels', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'accounts',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('pending_operations', kind: UpdateKind.delete)],
    ),
  ]);
}

typedef $$AccountsTableCreateCompanionBuilder =
    AccountsCompanion Function({
      Value<int> id,
      required String email,
      Value<String> displayName,
      required String username,
      required String imapHost,
      Value<int> imapPort,
      Value<SocketSecurity> imapSecurity,
      required String smtpHost,
      Value<int> smtpPort,
      Value<SocketSecurity> smtpSecurity,
      Value<String?> signature,
      Value<int> colorSeed,
      Value<bool> isActive,
      Value<AuthMethod> authMethod,
      Value<bool?> supportsKeywords,
      Value<String> capabilitiesJson,
      Value<DateTime> createdAt,
    });
typedef $$AccountsTableUpdateCompanionBuilder =
    AccountsCompanion Function({
      Value<int> id,
      Value<String> email,
      Value<String> displayName,
      Value<String> username,
      Value<String> imapHost,
      Value<int> imapPort,
      Value<SocketSecurity> imapSecurity,
      Value<String> smtpHost,
      Value<int> smtpPort,
      Value<SocketSecurity> smtpSecurity,
      Value<String?> signature,
      Value<int> colorSeed,
      Value<bool> isActive,
      Value<AuthMethod> authMethod,
      Value<bool?> supportsKeywords,
      Value<String> capabilitiesJson,
      Value<DateTime> createdAt,
    });

final class $$AccountsTableReferences
    extends BaseReferences<_$AppDatabase, $AccountsTable, AccountRow> {
  $$AccountsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$MailboxesTable, List<MailboxRow>>
  _mailboxesRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.mailboxes,
    aliasName: 'accounts__id__mailboxes__account_id',
  );

  $$MailboxesTableProcessedTableManager get mailboxesRefs {
    final manager = $$MailboxesTableTableManager(
      $_db,
      $_db.mailboxes,
    ).filter((f) => f.accountId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache = $_typedResult.readTableOrNull(_mailboxesRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$MessagesTable, List<MessageRow>>
  _messagesRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.messages,
    aliasName: 'accounts__id__messages__account_id',
  );

  $$MessagesTableProcessedTableManager get messagesRefs {
    final manager = $$MessagesTableTableManager(
      $_db,
      $_db.messages,
    ).filter((f) => f.accountId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache = $_typedResult.readTableOrNull(_messagesRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$LabelsTable, List<LabelRow>> _labelsRefsTable(
    _$AppDatabase db,
  ) => MultiTypedResultKey.fromTable(
    db.labels,
    aliasName: 'accounts__id__labels__account_id',
  );

  $$LabelsTableProcessedTableManager get labelsRefs {
    final manager = $$LabelsTableTableManager(
      $_db,
      $_db.labels,
    ).filter((f) => f.accountId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache = $_typedResult.readTableOrNull(_labelsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$PendingOperationsTable, List<PendingOperationRow>>
  _pendingOperationsRefsTable(_$AppDatabase db) =>
      MultiTypedResultKey.fromTable(
        db.pendingOperations,
        aliasName: 'accounts__id__pending_operations__account_id',
      );

  $$PendingOperationsTableProcessedTableManager get pendingOperationsRefs {
    final manager = $$PendingOperationsTableTableManager(
      $_db,
      $_db.pendingOperations,
    ).filter((f) => f.accountId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache = $_typedResult.readTableOrNull(
      _pendingOperationsRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$AccountsTableFilterComposer
    extends Composer<_$AppDatabase, $AccountsTable> {
  $$AccountsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get email => $composableBuilder(
    column: $table.email,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get username => $composableBuilder(
    column: $table.username,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get imapHost => $composableBuilder(
    column: $table.imapHost,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get imapPort => $composableBuilder(
    column: $table.imapPort,
    builder: (column) => ColumnFilters(column),
  );

  ColumnWithTypeConverterFilters<SocketSecurity, SocketSecurity, int>
  get imapSecurity => $composableBuilder(
    column: $table.imapSecurity,
    builder: (column) => ColumnWithTypeConverterFilters(column),
  );

  ColumnFilters<String> get smtpHost => $composableBuilder(
    column: $table.smtpHost,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get smtpPort => $composableBuilder(
    column: $table.smtpPort,
    builder: (column) => ColumnFilters(column),
  );

  ColumnWithTypeConverterFilters<SocketSecurity, SocketSecurity, int>
  get smtpSecurity => $composableBuilder(
    column: $table.smtpSecurity,
    builder: (column) => ColumnWithTypeConverterFilters(column),
  );

  ColumnFilters<String> get signature => $composableBuilder(
    column: $table.signature,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get colorSeed => $composableBuilder(
    column: $table.colorSeed,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isActive => $composableBuilder(
    column: $table.isActive,
    builder: (column) => ColumnFilters(column),
  );

  ColumnWithTypeConverterFilters<AuthMethod, AuthMethod, int> get authMethod =>
      $composableBuilder(
        column: $table.authMethod,
        builder: (column) => ColumnWithTypeConverterFilters(column),
      );

  ColumnFilters<bool> get supportsKeywords => $composableBuilder(
    column: $table.supportsKeywords,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get capabilitiesJson => $composableBuilder(
    column: $table.capabilitiesJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> mailboxesRefs(
    Expression<bool> Function($$MailboxesTableFilterComposer f) f,
  ) {
    final $$MailboxesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.mailboxes,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MailboxesTableFilterComposer(
            $db: $db,
            $table: $db.mailboxes,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> messagesRefs(
    Expression<bool> Function($$MessagesTableFilterComposer f) f,
  ) {
    final $$MessagesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.messages,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MessagesTableFilterComposer(
            $db: $db,
            $table: $db.messages,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> labelsRefs(
    Expression<bool> Function($$LabelsTableFilterComposer f) f,
  ) {
    final $$LabelsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.labels,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LabelsTableFilterComposer(
            $db: $db,
            $table: $db.labels,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> pendingOperationsRefs(
    Expression<bool> Function($$PendingOperationsTableFilterComposer f) f,
  ) {
    final $$PendingOperationsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.pendingOperations,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PendingOperationsTableFilterComposer(
            $db: $db,
            $table: $db.pendingOperations,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$AccountsTableOrderingComposer
    extends Composer<_$AppDatabase, $AccountsTable> {
  $$AccountsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get email => $composableBuilder(
    column: $table.email,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get username => $composableBuilder(
    column: $table.username,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get imapHost => $composableBuilder(
    column: $table.imapHost,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get imapPort => $composableBuilder(
    column: $table.imapPort,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get imapSecurity => $composableBuilder(
    column: $table.imapSecurity,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get smtpHost => $composableBuilder(
    column: $table.smtpHost,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get smtpPort => $composableBuilder(
    column: $table.smtpPort,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get smtpSecurity => $composableBuilder(
    column: $table.smtpSecurity,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get signature => $composableBuilder(
    column: $table.signature,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get colorSeed => $composableBuilder(
    column: $table.colorSeed,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isActive => $composableBuilder(
    column: $table.isActive,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get authMethod => $composableBuilder(
    column: $table.authMethod,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get supportsKeywords => $composableBuilder(
    column: $table.supportsKeywords,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get capabilitiesJson => $composableBuilder(
    column: $table.capabilitiesJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$AccountsTableAnnotationComposer
    extends Composer<_$AppDatabase, $AccountsTable> {
  $$AccountsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get email =>
      $composableBuilder(column: $table.email, builder: (column) => column);

  GeneratedColumn<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => column,
  );

  GeneratedColumn<String> get username =>
      $composableBuilder(column: $table.username, builder: (column) => column);

  GeneratedColumn<String> get imapHost =>
      $composableBuilder(column: $table.imapHost, builder: (column) => column);

  GeneratedColumn<int> get imapPort =>
      $composableBuilder(column: $table.imapPort, builder: (column) => column);

  GeneratedColumnWithTypeConverter<SocketSecurity, int> get imapSecurity =>
      $composableBuilder(
        column: $table.imapSecurity,
        builder: (column) => column,
      );

  GeneratedColumn<String> get smtpHost =>
      $composableBuilder(column: $table.smtpHost, builder: (column) => column);

  GeneratedColumn<int> get smtpPort =>
      $composableBuilder(column: $table.smtpPort, builder: (column) => column);

  GeneratedColumnWithTypeConverter<SocketSecurity, int> get smtpSecurity =>
      $composableBuilder(
        column: $table.smtpSecurity,
        builder: (column) => column,
      );

  GeneratedColumn<String> get signature =>
      $composableBuilder(column: $table.signature, builder: (column) => column);

  GeneratedColumn<int> get colorSeed =>
      $composableBuilder(column: $table.colorSeed, builder: (column) => column);

  GeneratedColumn<bool> get isActive =>
      $composableBuilder(column: $table.isActive, builder: (column) => column);

  GeneratedColumnWithTypeConverter<AuthMethod, int> get authMethod =>
      $composableBuilder(
        column: $table.authMethod,
        builder: (column) => column,
      );

  GeneratedColumn<bool> get supportsKeywords => $composableBuilder(
    column: $table.supportsKeywords,
    builder: (column) => column,
  );

  GeneratedColumn<String> get capabilitiesJson => $composableBuilder(
    column: $table.capabilitiesJson,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  Expression<T> mailboxesRefs<T extends Object>(
    Expression<T> Function($$MailboxesTableAnnotationComposer a) f,
  ) {
    final $$MailboxesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.mailboxes,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MailboxesTableAnnotationComposer(
            $db: $db,
            $table: $db.mailboxes,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> messagesRefs<T extends Object>(
    Expression<T> Function($$MessagesTableAnnotationComposer a) f,
  ) {
    final $$MessagesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.messages,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MessagesTableAnnotationComposer(
            $db: $db,
            $table: $db.messages,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> labelsRefs<T extends Object>(
    Expression<T> Function($$LabelsTableAnnotationComposer a) f,
  ) {
    final $$LabelsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.labels,
      getReferencedColumn: (t) => t.accountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LabelsTableAnnotationComposer(
            $db: $db,
            $table: $db.labels,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> pendingOperationsRefs<T extends Object>(
    Expression<T> Function($$PendingOperationsTableAnnotationComposer a) f,
  ) {
    final $$PendingOperationsTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.id,
          referencedTable: $db.pendingOperations,
          getReferencedColumn: (t) => t.accountId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$PendingOperationsTableAnnotationComposer(
                $db: $db,
                $table: $db.pendingOperations,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }
}

class $$AccountsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $AccountsTable,
          AccountRow,
          $$AccountsTableFilterComposer,
          $$AccountsTableOrderingComposer,
          $$AccountsTableAnnotationComposer,
          $$AccountsTableCreateCompanionBuilder,
          $$AccountsTableUpdateCompanionBuilder,
          (AccountRow, $$AccountsTableReferences),
          AccountRow,
          PrefetchHooks Function({
            bool mailboxesRefs,
            bool messagesRefs,
            bool labelsRefs,
            bool pendingOperationsRefs,
          })
        > {
  $$AccountsTableTableManager(_$AppDatabase db, $AccountsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AccountsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AccountsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AccountsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> email = const Value.absent(),
                Value<String> displayName = const Value.absent(),
                Value<String> username = const Value.absent(),
                Value<String> imapHost = const Value.absent(),
                Value<int> imapPort = const Value.absent(),
                Value<SocketSecurity> imapSecurity = const Value.absent(),
                Value<String> smtpHost = const Value.absent(),
                Value<int> smtpPort = const Value.absent(),
                Value<SocketSecurity> smtpSecurity = const Value.absent(),
                Value<String?> signature = const Value.absent(),
                Value<int> colorSeed = const Value.absent(),
                Value<bool> isActive = const Value.absent(),
                Value<AuthMethod> authMethod = const Value.absent(),
                Value<bool?> supportsKeywords = const Value.absent(),
                Value<String> capabilitiesJson = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
              }) => AccountsCompanion(
                id: id,
                email: email,
                displayName: displayName,
                username: username,
                imapHost: imapHost,
                imapPort: imapPort,
                imapSecurity: imapSecurity,
                smtpHost: smtpHost,
                smtpPort: smtpPort,
                smtpSecurity: smtpSecurity,
                signature: signature,
                colorSeed: colorSeed,
                isActive: isActive,
                authMethod: authMethod,
                supportsKeywords: supportsKeywords,
                capabilitiesJson: capabilitiesJson,
                createdAt: createdAt,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String email,
                Value<String> displayName = const Value.absent(),
                required String username,
                required String imapHost,
                Value<int> imapPort = const Value.absent(),
                Value<SocketSecurity> imapSecurity = const Value.absent(),
                required String smtpHost,
                Value<int> smtpPort = const Value.absent(),
                Value<SocketSecurity> smtpSecurity = const Value.absent(),
                Value<String?> signature = const Value.absent(),
                Value<int> colorSeed = const Value.absent(),
                Value<bool> isActive = const Value.absent(),
                Value<AuthMethod> authMethod = const Value.absent(),
                Value<bool?> supportsKeywords = const Value.absent(),
                Value<String> capabilitiesJson = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
              }) => AccountsCompanion.insert(
                id: id,
                email: email,
                displayName: displayName,
                username: username,
                imapHost: imapHost,
                imapPort: imapPort,
                imapSecurity: imapSecurity,
                smtpHost: smtpHost,
                smtpPort: smtpPort,
                smtpSecurity: smtpSecurity,
                signature: signature,
                colorSeed: colorSeed,
                isActive: isActive,
                authMethod: authMethod,
                supportsKeywords: supportsKeywords,
                capabilitiesJson: capabilitiesJson,
                createdAt: createdAt,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$AccountsTable, AccountRow>(table),
                  $$AccountsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback:
              ({
                mailboxesRefs = false,
                messagesRefs = false,
                labelsRefs = false,
                pendingOperationsRefs = false,
              }) {
                return PrefetchHooks(
                  db: db,
                  explicitlyWatchedTables: [
                    if (mailboxesRefs) db.mailboxes,
                    if (messagesRefs) db.messages,
                    if (labelsRefs) db.labels,
                    if (pendingOperationsRefs) db.pendingOperations,
                  ],
                  addJoins: null,
                  getPrefetchedDataCallback: (items) async {
                    return [
                      if (mailboxesRefs)
                        await $_getPrefetchedData<
                          AccountRow,
                          $AccountsTable,
                          MailboxRow
                        >(
                          currentTable: table,
                          referencedTable: $$AccountsTableReferences
                              ._mailboxesRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$AccountsTableReferences(
                                db,
                                table,
                                p0,
                              ).mailboxesRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.accountId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (messagesRefs)
                        await $_getPrefetchedData<
                          AccountRow,
                          $AccountsTable,
                          MessageRow
                        >(
                          currentTable: table,
                          referencedTable: $$AccountsTableReferences
                              ._messagesRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$AccountsTableReferences(
                                db,
                                table,
                                p0,
                              ).messagesRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.accountId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (labelsRefs)
                        await $_getPrefetchedData<
                          AccountRow,
                          $AccountsTable,
                          LabelRow
                        >(
                          currentTable: table,
                          referencedTable: $$AccountsTableReferences
                              ._labelsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$AccountsTableReferences(
                                db,
                                table,
                                p0,
                              ).labelsRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.accountId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (pendingOperationsRefs)
                        await $_getPrefetchedData<
                          AccountRow,
                          $AccountsTable,
                          PendingOperationRow
                        >(
                          currentTable: table,
                          referencedTable: $$AccountsTableReferences
                              ._pendingOperationsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$AccountsTableReferences(
                                db,
                                table,
                                p0,
                              ).pendingOperationsRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.accountId == item.id,
                              ),
                          typedResults: items,
                        ),
                    ];
                  },
                );
              },
        ),
      );
}

typedef $$AccountsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $AccountsTable,
      AccountRow,
      $$AccountsTableFilterComposer,
      $$AccountsTableOrderingComposer,
      $$AccountsTableAnnotationComposer,
      $$AccountsTableCreateCompanionBuilder,
      $$AccountsTableUpdateCompanionBuilder,
      (AccountRow, $$AccountsTableReferences),
      AccountRow,
      PrefetchHooks Function({
        bool mailboxesRefs,
        bool messagesRefs,
        bool labelsRefs,
        bool pendingOperationsRefs,
      })
    >;
typedef $$MailboxesTableCreateCompanionBuilder =
    MailboxesCompanion Function({
      Value<int> id,
      required int accountId,
      required String path,
      Value<String> encodedPath,
      required String name,
      Value<SpecialUse> specialUse,
      Value<String> delimiter,
      Value<int?> uidValidity,
      Value<int?> uidNext,
      Value<int?> highestModSeq,
      Value<int> totalCount,
      Value<int> unreadCount,
      Value<bool> isSubscribed,
      Value<bool> isSelectable,
      Value<DateTime?> lastSyncAt,
      Value<int> sortOrder,
      Value<bool> hasMoreOnServer,
    });
typedef $$MailboxesTableUpdateCompanionBuilder =
    MailboxesCompanion Function({
      Value<int> id,
      Value<int> accountId,
      Value<String> path,
      Value<String> encodedPath,
      Value<String> name,
      Value<SpecialUse> specialUse,
      Value<String> delimiter,
      Value<int?> uidValidity,
      Value<int?> uidNext,
      Value<int?> highestModSeq,
      Value<int> totalCount,
      Value<int> unreadCount,
      Value<bool> isSubscribed,
      Value<bool> isSelectable,
      Value<DateTime?> lastSyncAt,
      Value<int> sortOrder,
      Value<bool> hasMoreOnServer,
    });

final class $$MailboxesTableReferences
    extends BaseReferences<_$AppDatabase, $MailboxesTable, MailboxRow> {
  $$MailboxesTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $AccountsTable _accountIdTable(_$AppDatabase db) =>
      db.accounts.createAlias('mailboxes__account_id__accounts__id');

  $$AccountsTableProcessedTableManager get accountId {
    final $_column = $_itemColumn<int>('account_id')!;

    final manager = $$AccountsTableTableManager(
      $_db,
      $_db.accounts,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_accountIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static MultiTypedResultKey<$MessagesTable, List<MessageRow>>
  _messagesRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.messages,
    aliasName: 'mailboxes__id__messages__mailbox_id',
  );

  $$MessagesTableProcessedTableManager get messagesRefs {
    final manager = $$MessagesTableTableManager(
      $_db,
      $_db.messages,
    ).filter((f) => f.mailboxId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache = $_typedResult.readTableOrNull(_messagesRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$MailboxesTableFilterComposer
    extends Composer<_$AppDatabase, $MailboxesTable> {
  $$MailboxesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get path => $composableBuilder(
    column: $table.path,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get encodedPath => $composableBuilder(
    column: $table.encodedPath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnWithTypeConverterFilters<SpecialUse, SpecialUse, int> get specialUse =>
      $composableBuilder(
        column: $table.specialUse,
        builder: (column) => ColumnWithTypeConverterFilters(column),
      );

  ColumnFilters<String> get delimiter => $composableBuilder(
    column: $table.delimiter,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get uidValidity => $composableBuilder(
    column: $table.uidValidity,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get uidNext => $composableBuilder(
    column: $table.uidNext,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get highestModSeq => $composableBuilder(
    column: $table.highestModSeq,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get totalCount => $composableBuilder(
    column: $table.totalCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get unreadCount => $composableBuilder(
    column: $table.unreadCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isSubscribed => $composableBuilder(
    column: $table.isSubscribed,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isSelectable => $composableBuilder(
    column: $table.isSelectable,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get lastSyncAt => $composableBuilder(
    column: $table.lastSyncAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get hasMoreOnServer => $composableBuilder(
    column: $table.hasMoreOnServer,
    builder: (column) => ColumnFilters(column),
  );

  $$AccountsTableFilterComposer get accountId {
    final $$AccountsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.accounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AccountsTableFilterComposer(
            $db: $db,
            $table: $db.accounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<bool> messagesRefs(
    Expression<bool> Function($$MessagesTableFilterComposer f) f,
  ) {
    final $$MessagesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.messages,
      getReferencedColumn: (t) => t.mailboxId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MessagesTableFilterComposer(
            $db: $db,
            $table: $db.messages,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$MailboxesTableOrderingComposer
    extends Composer<_$AppDatabase, $MailboxesTable> {
  $$MailboxesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get path => $composableBuilder(
    column: $table.path,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get encodedPath => $composableBuilder(
    column: $table.encodedPath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get specialUse => $composableBuilder(
    column: $table.specialUse,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get delimiter => $composableBuilder(
    column: $table.delimiter,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get uidValidity => $composableBuilder(
    column: $table.uidValidity,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get uidNext => $composableBuilder(
    column: $table.uidNext,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get highestModSeq => $composableBuilder(
    column: $table.highestModSeq,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get totalCount => $composableBuilder(
    column: $table.totalCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get unreadCount => $composableBuilder(
    column: $table.unreadCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isSubscribed => $composableBuilder(
    column: $table.isSubscribed,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isSelectable => $composableBuilder(
    column: $table.isSelectable,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get lastSyncAt => $composableBuilder(
    column: $table.lastSyncAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get hasMoreOnServer => $composableBuilder(
    column: $table.hasMoreOnServer,
    builder: (column) => ColumnOrderings(column),
  );

  $$AccountsTableOrderingComposer get accountId {
    final $$AccountsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.accounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AccountsTableOrderingComposer(
            $db: $db,
            $table: $db.accounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$MailboxesTableAnnotationComposer
    extends Composer<_$AppDatabase, $MailboxesTable> {
  $$MailboxesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get path =>
      $composableBuilder(column: $table.path, builder: (column) => column);

  GeneratedColumn<String> get encodedPath => $composableBuilder(
    column: $table.encodedPath,
    builder: (column) => column,
  );

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumnWithTypeConverter<SpecialUse, int> get specialUse =>
      $composableBuilder(
        column: $table.specialUse,
        builder: (column) => column,
      );

  GeneratedColumn<String> get delimiter =>
      $composableBuilder(column: $table.delimiter, builder: (column) => column);

  GeneratedColumn<int> get uidValidity => $composableBuilder(
    column: $table.uidValidity,
    builder: (column) => column,
  );

  GeneratedColumn<int> get uidNext =>
      $composableBuilder(column: $table.uidNext, builder: (column) => column);

  GeneratedColumn<int> get highestModSeq => $composableBuilder(
    column: $table.highestModSeq,
    builder: (column) => column,
  );

  GeneratedColumn<int> get totalCount => $composableBuilder(
    column: $table.totalCount,
    builder: (column) => column,
  );

  GeneratedColumn<int> get unreadCount => $composableBuilder(
    column: $table.unreadCount,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get isSubscribed => $composableBuilder(
    column: $table.isSubscribed,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get isSelectable => $composableBuilder(
    column: $table.isSelectable,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get lastSyncAt => $composableBuilder(
    column: $table.lastSyncAt,
    builder: (column) => column,
  );

  GeneratedColumn<int> get sortOrder =>
      $composableBuilder(column: $table.sortOrder, builder: (column) => column);

  GeneratedColumn<bool> get hasMoreOnServer => $composableBuilder(
    column: $table.hasMoreOnServer,
    builder: (column) => column,
  );

  $$AccountsTableAnnotationComposer get accountId {
    final $$AccountsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.accounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AccountsTableAnnotationComposer(
            $db: $db,
            $table: $db.accounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<T> messagesRefs<T extends Object>(
    Expression<T> Function($$MessagesTableAnnotationComposer a) f,
  ) {
    final $$MessagesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.messages,
      getReferencedColumn: (t) => t.mailboxId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MessagesTableAnnotationComposer(
            $db: $db,
            $table: $db.messages,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$MailboxesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $MailboxesTable,
          MailboxRow,
          $$MailboxesTableFilterComposer,
          $$MailboxesTableOrderingComposer,
          $$MailboxesTableAnnotationComposer,
          $$MailboxesTableCreateCompanionBuilder,
          $$MailboxesTableUpdateCompanionBuilder,
          (MailboxRow, $$MailboxesTableReferences),
          MailboxRow,
          PrefetchHooks Function({bool accountId, bool messagesRefs})
        > {
  $$MailboxesTableTableManager(_$AppDatabase db, $MailboxesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MailboxesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MailboxesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MailboxesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> accountId = const Value.absent(),
                Value<String> path = const Value.absent(),
                Value<String> encodedPath = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<SpecialUse> specialUse = const Value.absent(),
                Value<String> delimiter = const Value.absent(),
                Value<int?> uidValidity = const Value.absent(),
                Value<int?> uidNext = const Value.absent(),
                Value<int?> highestModSeq = const Value.absent(),
                Value<int> totalCount = const Value.absent(),
                Value<int> unreadCount = const Value.absent(),
                Value<bool> isSubscribed = const Value.absent(),
                Value<bool> isSelectable = const Value.absent(),
                Value<DateTime?> lastSyncAt = const Value.absent(),
                Value<int> sortOrder = const Value.absent(),
                Value<bool> hasMoreOnServer = const Value.absent(),
              }) => MailboxesCompanion(
                id: id,
                accountId: accountId,
                path: path,
                encodedPath: encodedPath,
                name: name,
                specialUse: specialUse,
                delimiter: delimiter,
                uidValidity: uidValidity,
                uidNext: uidNext,
                highestModSeq: highestModSeq,
                totalCount: totalCount,
                unreadCount: unreadCount,
                isSubscribed: isSubscribed,
                isSelectable: isSelectable,
                lastSyncAt: lastSyncAt,
                sortOrder: sortOrder,
                hasMoreOnServer: hasMoreOnServer,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required int accountId,
                required String path,
                Value<String> encodedPath = const Value.absent(),
                required String name,
                Value<SpecialUse> specialUse = const Value.absent(),
                Value<String> delimiter = const Value.absent(),
                Value<int?> uidValidity = const Value.absent(),
                Value<int?> uidNext = const Value.absent(),
                Value<int?> highestModSeq = const Value.absent(),
                Value<int> totalCount = const Value.absent(),
                Value<int> unreadCount = const Value.absent(),
                Value<bool> isSubscribed = const Value.absent(),
                Value<bool> isSelectable = const Value.absent(),
                Value<DateTime?> lastSyncAt = const Value.absent(),
                Value<int> sortOrder = const Value.absent(),
                Value<bool> hasMoreOnServer = const Value.absent(),
              }) => MailboxesCompanion.insert(
                id: id,
                accountId: accountId,
                path: path,
                encodedPath: encodedPath,
                name: name,
                specialUse: specialUse,
                delimiter: delimiter,
                uidValidity: uidValidity,
                uidNext: uidNext,
                highestModSeq: highestModSeq,
                totalCount: totalCount,
                unreadCount: unreadCount,
                isSubscribed: isSubscribed,
                isSelectable: isSelectable,
                lastSyncAt: lastSyncAt,
                sortOrder: sortOrder,
                hasMoreOnServer: hasMoreOnServer,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$MailboxesTable, MailboxRow>(table),
                  $$MailboxesTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({accountId = false, messagesRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [if (messagesRefs) db.messages],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (accountId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.accountId,
                                referencedTable: $$MailboxesTableReferences
                                    ._accountIdTable(db),
                                referencedColumn: $$MailboxesTableReferences
                                    ._accountIdTable(db)
                                    .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [
                  if (messagesRefs)
                    await $_getPrefetchedData<
                      MailboxRow,
                      $MailboxesTable,
                      MessageRow
                    >(
                      currentTable: table,
                      referencedTable: $$MailboxesTableReferences
                          ._messagesRefsTable(db),
                      managerFromTypedResult: (p0) =>
                          $$MailboxesTableReferences(
                            db,
                            table,
                            p0,
                          ).messagesRefs,
                      referencedItemsForCurrentItem: (item, referencedItems) =>
                          referencedItems.where((e) => e.mailboxId == item.id),
                      typedResults: items,
                    ),
                ];
              },
            );
          },
        ),
      );
}

typedef $$MailboxesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $MailboxesTable,
      MailboxRow,
      $$MailboxesTableFilterComposer,
      $$MailboxesTableOrderingComposer,
      $$MailboxesTableAnnotationComposer,
      $$MailboxesTableCreateCompanionBuilder,
      $$MailboxesTableUpdateCompanionBuilder,
      (MailboxRow, $$MailboxesTableReferences),
      MailboxRow,
      PrefetchHooks Function({bool accountId, bool messagesRefs})
    >;
typedef $$MessagesTableCreateCompanionBuilder =
    MessagesCompanion Function({
      Value<int> id,
      required int accountId,
      required int mailboxId,
      Value<int?> uid,
      Value<String?> messageIdHeader,
      Value<String?> inReplyTo,
      Value<String?> referencesRaw,
      Value<String> threadId,
      Value<String> fromName,
      Value<String> fromEmail,
      Value<String> toAddrJson,
      Value<String> ccJson,
      Value<String> bccJson,
      Value<String> subject,
      Value<String> subjectNormalized,
      Value<String> preview,
      required DateTime dateUtc,
      Value<bool> isSeen,
      Value<bool> isFlagged,
      Value<bool> isAnswered,
      Value<bool> isDraft,
      Value<bool> isDeleted,
      Value<bool> hasAttachments,
      Value<int> sizeBytes,
      Value<DateTime?> bodyFetchedAt,
      Value<String> labelsJson,
      Value<bool> isLocalOnly,
      Value<OutboxState> outboxState,
      Value<String?> outboxError,
      Value<int?> replyToMessageId,
    });
typedef $$MessagesTableUpdateCompanionBuilder =
    MessagesCompanion Function({
      Value<int> id,
      Value<int> accountId,
      Value<int> mailboxId,
      Value<int?> uid,
      Value<String?> messageIdHeader,
      Value<String?> inReplyTo,
      Value<String?> referencesRaw,
      Value<String> threadId,
      Value<String> fromName,
      Value<String> fromEmail,
      Value<String> toAddrJson,
      Value<String> ccJson,
      Value<String> bccJson,
      Value<String> subject,
      Value<String> subjectNormalized,
      Value<String> preview,
      Value<DateTime> dateUtc,
      Value<bool> isSeen,
      Value<bool> isFlagged,
      Value<bool> isAnswered,
      Value<bool> isDraft,
      Value<bool> isDeleted,
      Value<bool> hasAttachments,
      Value<int> sizeBytes,
      Value<DateTime?> bodyFetchedAt,
      Value<String> labelsJson,
      Value<bool> isLocalOnly,
      Value<OutboxState> outboxState,
      Value<String?> outboxError,
      Value<int?> replyToMessageId,
    });

final class $$MessagesTableReferences
    extends BaseReferences<_$AppDatabase, $MessagesTable, MessageRow> {
  $$MessagesTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $AccountsTable _accountIdTable(_$AppDatabase db) =>
      db.accounts.createAlias('messages__account_id__accounts__id');

  $$AccountsTableProcessedTableManager get accountId {
    final $_column = $_itemColumn<int>('account_id')!;

    final manager = $$AccountsTableTableManager(
      $_db,
      $_db.accounts,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_accountIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static $MailboxesTable _mailboxIdTable(_$AppDatabase db) =>
      db.mailboxes.createAlias('messages__mailbox_id__mailboxes__id');

  $$MailboxesTableProcessedTableManager get mailboxId {
    final $_column = $_itemColumn<int>('mailbox_id')!;

    final manager = $$MailboxesTableTableManager(
      $_db,
      $_db.mailboxes,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_mailboxIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static MultiTypedResultKey<$MessageBodiesTable, List<MessageBodyRow>>
  _messageBodiesRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.messageBodies,
    aliasName: 'messages__id__message_bodies__message_id',
  );

  $$MessageBodiesTableProcessedTableManager get messageBodiesRefs {
    final manager = $$MessageBodiesTableTableManager(
      $_db,
      $_db.messageBodies,
    ).filter((f) => f.messageId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache = $_typedResult.readTableOrNull(_messageBodiesRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$AttachmentsTable, List<AttachmentRow>>
  _attachmentsRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.attachments,
    aliasName: 'messages__id__attachments__message_id',
  );

  $$AttachmentsTableProcessedTableManager get attachmentsRefs {
    final manager = $$AttachmentsTableTableManager(
      $_db,
      $_db.attachments,
    ).filter((f) => f.messageId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache = $_typedResult.readTableOrNull(_attachmentsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$MessagesTableFilterComposer
    extends Composer<_$AppDatabase, $MessagesTable> {
  $$MessagesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get uid => $composableBuilder(
    column: $table.uid,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get messageIdHeader => $composableBuilder(
    column: $table.messageIdHeader,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get inReplyTo => $composableBuilder(
    column: $table.inReplyTo,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get referencesRaw => $composableBuilder(
    column: $table.referencesRaw,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get threadId => $composableBuilder(
    column: $table.threadId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get fromName => $composableBuilder(
    column: $table.fromName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get fromEmail => $composableBuilder(
    column: $table.fromEmail,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get toAddrJson => $composableBuilder(
    column: $table.toAddrJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get ccJson => $composableBuilder(
    column: $table.ccJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get bccJson => $composableBuilder(
    column: $table.bccJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get subject => $composableBuilder(
    column: $table.subject,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get subjectNormalized => $composableBuilder(
    column: $table.subjectNormalized,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get preview => $composableBuilder(
    column: $table.preview,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get dateUtc => $composableBuilder(
    column: $table.dateUtc,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isSeen => $composableBuilder(
    column: $table.isSeen,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isFlagged => $composableBuilder(
    column: $table.isFlagged,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isAnswered => $composableBuilder(
    column: $table.isAnswered,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isDraft => $composableBuilder(
    column: $table.isDraft,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isDeleted => $composableBuilder(
    column: $table.isDeleted,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get hasAttachments => $composableBuilder(
    column: $table.hasAttachments,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sizeBytes => $composableBuilder(
    column: $table.sizeBytes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get bodyFetchedAt => $composableBuilder(
    column: $table.bodyFetchedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get labelsJson => $composableBuilder(
    column: $table.labelsJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isLocalOnly => $composableBuilder(
    column: $table.isLocalOnly,
    builder: (column) => ColumnFilters(column),
  );

  ColumnWithTypeConverterFilters<OutboxState, OutboxState, int>
  get outboxState => $composableBuilder(
    column: $table.outboxState,
    builder: (column) => ColumnWithTypeConverterFilters(column),
  );

  ColumnFilters<String> get outboxError => $composableBuilder(
    column: $table.outboxError,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get replyToMessageId => $composableBuilder(
    column: $table.replyToMessageId,
    builder: (column) => ColumnFilters(column),
  );

  $$AccountsTableFilterComposer get accountId {
    final $$AccountsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.accounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AccountsTableFilterComposer(
            $db: $db,
            $table: $db.accounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$MailboxesTableFilterComposer get mailboxId {
    final $$MailboxesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.mailboxId,
      referencedTable: $db.mailboxes,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MailboxesTableFilterComposer(
            $db: $db,
            $table: $db.mailboxes,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<bool> messageBodiesRefs(
    Expression<bool> Function($$MessageBodiesTableFilterComposer f) f,
  ) {
    final $$MessageBodiesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.messageBodies,
      getReferencedColumn: (t) => t.messageId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MessageBodiesTableFilterComposer(
            $db: $db,
            $table: $db.messageBodies,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> attachmentsRefs(
    Expression<bool> Function($$AttachmentsTableFilterComposer f) f,
  ) {
    final $$AttachmentsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.attachments,
      getReferencedColumn: (t) => t.messageId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AttachmentsTableFilterComposer(
            $db: $db,
            $table: $db.attachments,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$MessagesTableOrderingComposer
    extends Composer<_$AppDatabase, $MessagesTable> {
  $$MessagesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get uid => $composableBuilder(
    column: $table.uid,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get messageIdHeader => $composableBuilder(
    column: $table.messageIdHeader,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get inReplyTo => $composableBuilder(
    column: $table.inReplyTo,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get referencesRaw => $composableBuilder(
    column: $table.referencesRaw,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get threadId => $composableBuilder(
    column: $table.threadId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get fromName => $composableBuilder(
    column: $table.fromName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get fromEmail => $composableBuilder(
    column: $table.fromEmail,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get toAddrJson => $composableBuilder(
    column: $table.toAddrJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get ccJson => $composableBuilder(
    column: $table.ccJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get bccJson => $composableBuilder(
    column: $table.bccJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get subject => $composableBuilder(
    column: $table.subject,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get subjectNormalized => $composableBuilder(
    column: $table.subjectNormalized,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get preview => $composableBuilder(
    column: $table.preview,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get dateUtc => $composableBuilder(
    column: $table.dateUtc,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isSeen => $composableBuilder(
    column: $table.isSeen,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isFlagged => $composableBuilder(
    column: $table.isFlagged,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isAnswered => $composableBuilder(
    column: $table.isAnswered,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isDraft => $composableBuilder(
    column: $table.isDraft,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isDeleted => $composableBuilder(
    column: $table.isDeleted,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get hasAttachments => $composableBuilder(
    column: $table.hasAttachments,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sizeBytes => $composableBuilder(
    column: $table.sizeBytes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get bodyFetchedAt => $composableBuilder(
    column: $table.bodyFetchedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get labelsJson => $composableBuilder(
    column: $table.labelsJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isLocalOnly => $composableBuilder(
    column: $table.isLocalOnly,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get outboxState => $composableBuilder(
    column: $table.outboxState,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get outboxError => $composableBuilder(
    column: $table.outboxError,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get replyToMessageId => $composableBuilder(
    column: $table.replyToMessageId,
    builder: (column) => ColumnOrderings(column),
  );

  $$AccountsTableOrderingComposer get accountId {
    final $$AccountsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.accounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AccountsTableOrderingComposer(
            $db: $db,
            $table: $db.accounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$MailboxesTableOrderingComposer get mailboxId {
    final $$MailboxesTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.mailboxId,
      referencedTable: $db.mailboxes,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MailboxesTableOrderingComposer(
            $db: $db,
            $table: $db.mailboxes,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$MessagesTableAnnotationComposer
    extends Composer<_$AppDatabase, $MessagesTable> {
  $$MessagesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get uid =>
      $composableBuilder(column: $table.uid, builder: (column) => column);

  GeneratedColumn<String> get messageIdHeader => $composableBuilder(
    column: $table.messageIdHeader,
    builder: (column) => column,
  );

  GeneratedColumn<String> get inReplyTo =>
      $composableBuilder(column: $table.inReplyTo, builder: (column) => column);

  GeneratedColumn<String> get referencesRaw => $composableBuilder(
    column: $table.referencesRaw,
    builder: (column) => column,
  );

  GeneratedColumn<String> get threadId =>
      $composableBuilder(column: $table.threadId, builder: (column) => column);

  GeneratedColumn<String> get fromName =>
      $composableBuilder(column: $table.fromName, builder: (column) => column);

  GeneratedColumn<String> get fromEmail =>
      $composableBuilder(column: $table.fromEmail, builder: (column) => column);

  GeneratedColumn<String> get toAddrJson => $composableBuilder(
    column: $table.toAddrJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get ccJson =>
      $composableBuilder(column: $table.ccJson, builder: (column) => column);

  GeneratedColumn<String> get bccJson =>
      $composableBuilder(column: $table.bccJson, builder: (column) => column);

  GeneratedColumn<String> get subject =>
      $composableBuilder(column: $table.subject, builder: (column) => column);

  GeneratedColumn<String> get subjectNormalized => $composableBuilder(
    column: $table.subjectNormalized,
    builder: (column) => column,
  );

  GeneratedColumn<String> get preview =>
      $composableBuilder(column: $table.preview, builder: (column) => column);

  GeneratedColumn<DateTime> get dateUtc =>
      $composableBuilder(column: $table.dateUtc, builder: (column) => column);

  GeneratedColumn<bool> get isSeen =>
      $composableBuilder(column: $table.isSeen, builder: (column) => column);

  GeneratedColumn<bool> get isFlagged =>
      $composableBuilder(column: $table.isFlagged, builder: (column) => column);

  GeneratedColumn<bool> get isAnswered => $composableBuilder(
    column: $table.isAnswered,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get isDraft =>
      $composableBuilder(column: $table.isDraft, builder: (column) => column);

  GeneratedColumn<bool> get isDeleted =>
      $composableBuilder(column: $table.isDeleted, builder: (column) => column);

  GeneratedColumn<bool> get hasAttachments => $composableBuilder(
    column: $table.hasAttachments,
    builder: (column) => column,
  );

  GeneratedColumn<int> get sizeBytes =>
      $composableBuilder(column: $table.sizeBytes, builder: (column) => column);

  GeneratedColumn<DateTime> get bodyFetchedAt => $composableBuilder(
    column: $table.bodyFetchedAt,
    builder: (column) => column,
  );

  GeneratedColumn<String> get labelsJson => $composableBuilder(
    column: $table.labelsJson,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get isLocalOnly => $composableBuilder(
    column: $table.isLocalOnly,
    builder: (column) => column,
  );

  GeneratedColumnWithTypeConverter<OutboxState, int> get outboxState =>
      $composableBuilder(
        column: $table.outboxState,
        builder: (column) => column,
      );

  GeneratedColumn<String> get outboxError => $composableBuilder(
    column: $table.outboxError,
    builder: (column) => column,
  );

  GeneratedColumn<int> get replyToMessageId => $composableBuilder(
    column: $table.replyToMessageId,
    builder: (column) => column,
  );

  $$AccountsTableAnnotationComposer get accountId {
    final $$AccountsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.accounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AccountsTableAnnotationComposer(
            $db: $db,
            $table: $db.accounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$MailboxesTableAnnotationComposer get mailboxId {
    final $$MailboxesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.mailboxId,
      referencedTable: $db.mailboxes,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MailboxesTableAnnotationComposer(
            $db: $db,
            $table: $db.mailboxes,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<T> messageBodiesRefs<T extends Object>(
    Expression<T> Function($$MessageBodiesTableAnnotationComposer a) f,
  ) {
    final $$MessageBodiesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.messageBodies,
      getReferencedColumn: (t) => t.messageId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MessageBodiesTableAnnotationComposer(
            $db: $db,
            $table: $db.messageBodies,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> attachmentsRefs<T extends Object>(
    Expression<T> Function($$AttachmentsTableAnnotationComposer a) f,
  ) {
    final $$AttachmentsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.attachments,
      getReferencedColumn: (t) => t.messageId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AttachmentsTableAnnotationComposer(
            $db: $db,
            $table: $db.attachments,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$MessagesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $MessagesTable,
          MessageRow,
          $$MessagesTableFilterComposer,
          $$MessagesTableOrderingComposer,
          $$MessagesTableAnnotationComposer,
          $$MessagesTableCreateCompanionBuilder,
          $$MessagesTableUpdateCompanionBuilder,
          (MessageRow, $$MessagesTableReferences),
          MessageRow,
          PrefetchHooks Function({
            bool accountId,
            bool mailboxId,
            bool messageBodiesRefs,
            bool attachmentsRefs,
          })
        > {
  $$MessagesTableTableManager(_$AppDatabase db, $MessagesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MessagesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MessagesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MessagesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> accountId = const Value.absent(),
                Value<int> mailboxId = const Value.absent(),
                Value<int?> uid = const Value.absent(),
                Value<String?> messageIdHeader = const Value.absent(),
                Value<String?> inReplyTo = const Value.absent(),
                Value<String?> referencesRaw = const Value.absent(),
                Value<String> threadId = const Value.absent(),
                Value<String> fromName = const Value.absent(),
                Value<String> fromEmail = const Value.absent(),
                Value<String> toAddrJson = const Value.absent(),
                Value<String> ccJson = const Value.absent(),
                Value<String> bccJson = const Value.absent(),
                Value<String> subject = const Value.absent(),
                Value<String> subjectNormalized = const Value.absent(),
                Value<String> preview = const Value.absent(),
                Value<DateTime> dateUtc = const Value.absent(),
                Value<bool> isSeen = const Value.absent(),
                Value<bool> isFlagged = const Value.absent(),
                Value<bool> isAnswered = const Value.absent(),
                Value<bool> isDraft = const Value.absent(),
                Value<bool> isDeleted = const Value.absent(),
                Value<bool> hasAttachments = const Value.absent(),
                Value<int> sizeBytes = const Value.absent(),
                Value<DateTime?> bodyFetchedAt = const Value.absent(),
                Value<String> labelsJson = const Value.absent(),
                Value<bool> isLocalOnly = const Value.absent(),
                Value<OutboxState> outboxState = const Value.absent(),
                Value<String?> outboxError = const Value.absent(),
                Value<int?> replyToMessageId = const Value.absent(),
              }) => MessagesCompanion(
                id: id,
                accountId: accountId,
                mailboxId: mailboxId,
                uid: uid,
                messageIdHeader: messageIdHeader,
                inReplyTo: inReplyTo,
                referencesRaw: referencesRaw,
                threadId: threadId,
                fromName: fromName,
                fromEmail: fromEmail,
                toAddrJson: toAddrJson,
                ccJson: ccJson,
                bccJson: bccJson,
                subject: subject,
                subjectNormalized: subjectNormalized,
                preview: preview,
                dateUtc: dateUtc,
                isSeen: isSeen,
                isFlagged: isFlagged,
                isAnswered: isAnswered,
                isDraft: isDraft,
                isDeleted: isDeleted,
                hasAttachments: hasAttachments,
                sizeBytes: sizeBytes,
                bodyFetchedAt: bodyFetchedAt,
                labelsJson: labelsJson,
                isLocalOnly: isLocalOnly,
                outboxState: outboxState,
                outboxError: outboxError,
                replyToMessageId: replyToMessageId,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required int accountId,
                required int mailboxId,
                Value<int?> uid = const Value.absent(),
                Value<String?> messageIdHeader = const Value.absent(),
                Value<String?> inReplyTo = const Value.absent(),
                Value<String?> referencesRaw = const Value.absent(),
                Value<String> threadId = const Value.absent(),
                Value<String> fromName = const Value.absent(),
                Value<String> fromEmail = const Value.absent(),
                Value<String> toAddrJson = const Value.absent(),
                Value<String> ccJson = const Value.absent(),
                Value<String> bccJson = const Value.absent(),
                Value<String> subject = const Value.absent(),
                Value<String> subjectNormalized = const Value.absent(),
                Value<String> preview = const Value.absent(),
                required DateTime dateUtc,
                Value<bool> isSeen = const Value.absent(),
                Value<bool> isFlagged = const Value.absent(),
                Value<bool> isAnswered = const Value.absent(),
                Value<bool> isDraft = const Value.absent(),
                Value<bool> isDeleted = const Value.absent(),
                Value<bool> hasAttachments = const Value.absent(),
                Value<int> sizeBytes = const Value.absent(),
                Value<DateTime?> bodyFetchedAt = const Value.absent(),
                Value<String> labelsJson = const Value.absent(),
                Value<bool> isLocalOnly = const Value.absent(),
                Value<OutboxState> outboxState = const Value.absent(),
                Value<String?> outboxError = const Value.absent(),
                Value<int?> replyToMessageId = const Value.absent(),
              }) => MessagesCompanion.insert(
                id: id,
                accountId: accountId,
                mailboxId: mailboxId,
                uid: uid,
                messageIdHeader: messageIdHeader,
                inReplyTo: inReplyTo,
                referencesRaw: referencesRaw,
                threadId: threadId,
                fromName: fromName,
                fromEmail: fromEmail,
                toAddrJson: toAddrJson,
                ccJson: ccJson,
                bccJson: bccJson,
                subject: subject,
                subjectNormalized: subjectNormalized,
                preview: preview,
                dateUtc: dateUtc,
                isSeen: isSeen,
                isFlagged: isFlagged,
                isAnswered: isAnswered,
                isDraft: isDraft,
                isDeleted: isDeleted,
                hasAttachments: hasAttachments,
                sizeBytes: sizeBytes,
                bodyFetchedAt: bodyFetchedAt,
                labelsJson: labelsJson,
                isLocalOnly: isLocalOnly,
                outboxState: outboxState,
                outboxError: outboxError,
                replyToMessageId: replyToMessageId,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$MessagesTable, MessageRow>(table),
                  $$MessagesTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback:
              ({
                accountId = false,
                mailboxId = false,
                messageBodiesRefs = false,
                attachmentsRefs = false,
              }) {
                return PrefetchHooks(
                  db: db,
                  explicitlyWatchedTables: [
                    if (messageBodiesRefs) db.messageBodies,
                    if (attachmentsRefs) db.attachments,
                  ],
                  addJoins:
                      <
                        T extends TableManagerState<
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic
                        >
                      >(state) {
                        if (accountId) {
                          state =
                              state.withJoin(
                                    currentTable: table,
                                    currentColumn: table.accountId,
                                    referencedTable: $$MessagesTableReferences
                                        ._accountIdTable(db),
                                    referencedColumn: $$MessagesTableReferences
                                        ._accountIdTable(db)
                                        .id,
                                  )
                                  as T;
                        }
                        if (mailboxId) {
                          state =
                              state.withJoin(
                                    currentTable: table,
                                    currentColumn: table.mailboxId,
                                    referencedTable: $$MessagesTableReferences
                                        ._mailboxIdTable(db),
                                    referencedColumn: $$MessagesTableReferences
                                        ._mailboxIdTable(db)
                                        .id,
                                  )
                                  as T;
                        }

                        return state;
                      },
                  getPrefetchedDataCallback: (items) async {
                    return [
                      if (messageBodiesRefs)
                        await $_getPrefetchedData<
                          MessageRow,
                          $MessagesTable,
                          MessageBodyRow
                        >(
                          currentTable: table,
                          referencedTable: $$MessagesTableReferences
                              ._messageBodiesRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$MessagesTableReferences(
                                db,
                                table,
                                p0,
                              ).messageBodiesRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.messageId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (attachmentsRefs)
                        await $_getPrefetchedData<
                          MessageRow,
                          $MessagesTable,
                          AttachmentRow
                        >(
                          currentTable: table,
                          referencedTable: $$MessagesTableReferences
                              ._attachmentsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$MessagesTableReferences(
                                db,
                                table,
                                p0,
                              ).attachmentsRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.messageId == item.id,
                              ),
                          typedResults: items,
                        ),
                    ];
                  },
                );
              },
        ),
      );
}

typedef $$MessagesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $MessagesTable,
      MessageRow,
      $$MessagesTableFilterComposer,
      $$MessagesTableOrderingComposer,
      $$MessagesTableAnnotationComposer,
      $$MessagesTableCreateCompanionBuilder,
      $$MessagesTableUpdateCompanionBuilder,
      (MessageRow, $$MessagesTableReferences),
      MessageRow,
      PrefetchHooks Function({
        bool accountId,
        bool mailboxId,
        bool messageBodiesRefs,
        bool attachmentsRefs,
      })
    >;
typedef $$MessageBodiesTableCreateCompanionBuilder =
    MessageBodiesCompanion Function({
      Value<int> messageId,
      Value<String?> plainText,
      Value<String?> html,
      Value<DateTime> fetchedAt,
    });
typedef $$MessageBodiesTableUpdateCompanionBuilder =
    MessageBodiesCompanion Function({
      Value<int> messageId,
      Value<String?> plainText,
      Value<String?> html,
      Value<DateTime> fetchedAt,
    });

final class $$MessageBodiesTableReferences
    extends BaseReferences<_$AppDatabase, $MessageBodiesTable, MessageBodyRow> {
  $$MessageBodiesTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $MessagesTable _messageIdTable(_$AppDatabase db) =>
      db.messages.createAlias('message_bodies__message_id__messages__id');

  $$MessagesTableProcessedTableManager get messageId {
    final $_column = $_itemColumn<int>('message_id')!;

    final manager = $$MessagesTableTableManager(
      $_db,
      $_db.messages,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_messageIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$MessageBodiesTableFilterComposer
    extends Composer<_$AppDatabase, $MessageBodiesTable> {
  $$MessageBodiesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get plainText => $composableBuilder(
    column: $table.plainText,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get html => $composableBuilder(
    column: $table.html,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get fetchedAt => $composableBuilder(
    column: $table.fetchedAt,
    builder: (column) => ColumnFilters(column),
  );

  $$MessagesTableFilterComposer get messageId {
    final $$MessagesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.messageId,
      referencedTable: $db.messages,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MessagesTableFilterComposer(
            $db: $db,
            $table: $db.messages,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$MessageBodiesTableOrderingComposer
    extends Composer<_$AppDatabase, $MessageBodiesTable> {
  $$MessageBodiesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get plainText => $composableBuilder(
    column: $table.plainText,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get html => $composableBuilder(
    column: $table.html,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get fetchedAt => $composableBuilder(
    column: $table.fetchedAt,
    builder: (column) => ColumnOrderings(column),
  );

  $$MessagesTableOrderingComposer get messageId {
    final $$MessagesTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.messageId,
      referencedTable: $db.messages,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MessagesTableOrderingComposer(
            $db: $db,
            $table: $db.messages,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$MessageBodiesTableAnnotationComposer
    extends Composer<_$AppDatabase, $MessageBodiesTable> {
  $$MessageBodiesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get plainText =>
      $composableBuilder(column: $table.plainText, builder: (column) => column);

  GeneratedColumn<String> get html =>
      $composableBuilder(column: $table.html, builder: (column) => column);

  GeneratedColumn<DateTime> get fetchedAt =>
      $composableBuilder(column: $table.fetchedAt, builder: (column) => column);

  $$MessagesTableAnnotationComposer get messageId {
    final $$MessagesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.messageId,
      referencedTable: $db.messages,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MessagesTableAnnotationComposer(
            $db: $db,
            $table: $db.messages,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$MessageBodiesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $MessageBodiesTable,
          MessageBodyRow,
          $$MessageBodiesTableFilterComposer,
          $$MessageBodiesTableOrderingComposer,
          $$MessageBodiesTableAnnotationComposer,
          $$MessageBodiesTableCreateCompanionBuilder,
          $$MessageBodiesTableUpdateCompanionBuilder,
          (MessageBodyRow, $$MessageBodiesTableReferences),
          MessageBodyRow,
          PrefetchHooks Function({bool messageId})
        > {
  $$MessageBodiesTableTableManager(_$AppDatabase db, $MessageBodiesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MessageBodiesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MessageBodiesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MessageBodiesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> messageId = const Value.absent(),
                Value<String?> plainText = const Value.absent(),
                Value<String?> html = const Value.absent(),
                Value<DateTime> fetchedAt = const Value.absent(),
              }) => MessageBodiesCompanion(
                messageId: messageId,
                plainText: plainText,
                html: html,
                fetchedAt: fetchedAt,
              ),
          createCompanionCallback:
              ({
                Value<int> messageId = const Value.absent(),
                Value<String?> plainText = const Value.absent(),
                Value<String?> html = const Value.absent(),
                Value<DateTime> fetchedAt = const Value.absent(),
              }) => MessageBodiesCompanion.insert(
                messageId: messageId,
                plainText: plainText,
                html: html,
                fetchedAt: fetchedAt,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$MessageBodiesTable, MessageBodyRow>(table),
                  $$MessageBodiesTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({messageId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (messageId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.messageId,
                                referencedTable: $$MessageBodiesTableReferences
                                    ._messageIdTable(db),
                                referencedColumn: $$MessageBodiesTableReferences
                                    ._messageIdTable(db)
                                    .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$MessageBodiesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $MessageBodiesTable,
      MessageBodyRow,
      $$MessageBodiesTableFilterComposer,
      $$MessageBodiesTableOrderingComposer,
      $$MessageBodiesTableAnnotationComposer,
      $$MessageBodiesTableCreateCompanionBuilder,
      $$MessageBodiesTableUpdateCompanionBuilder,
      (MessageBodyRow, $$MessageBodiesTableReferences),
      MessageBodyRow,
      PrefetchHooks Function({bool messageId})
    >;
typedef $$AttachmentsTableCreateCompanionBuilder =
    AttachmentsCompanion Function({
      Value<int> id,
      required int messageId,
      Value<String> partId,
      Value<String> fileName,
      Value<String> mimeType,
      Value<int> sizeBytes,
      Value<String?> contentId,
      Value<bool> isInline,
      Value<String?> localPath,
      Value<bool> isOutgoing,
    });
typedef $$AttachmentsTableUpdateCompanionBuilder =
    AttachmentsCompanion Function({
      Value<int> id,
      Value<int> messageId,
      Value<String> partId,
      Value<String> fileName,
      Value<String> mimeType,
      Value<int> sizeBytes,
      Value<String?> contentId,
      Value<bool> isInline,
      Value<String?> localPath,
      Value<bool> isOutgoing,
    });

final class $$AttachmentsTableReferences
    extends BaseReferences<_$AppDatabase, $AttachmentsTable, AttachmentRow> {
  $$AttachmentsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $MessagesTable _messageIdTable(_$AppDatabase db) =>
      db.messages.createAlias('attachments__message_id__messages__id');

  $$MessagesTableProcessedTableManager get messageId {
    final $_column = $_itemColumn<int>('message_id')!;

    final manager = $$MessagesTableTableManager(
      $_db,
      $_db.messages,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_messageIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$AttachmentsTableFilterComposer
    extends Composer<_$AppDatabase, $AttachmentsTable> {
  $$AttachmentsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get partId => $composableBuilder(
    column: $table.partId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get fileName => $composableBuilder(
    column: $table.fileName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get mimeType => $composableBuilder(
    column: $table.mimeType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sizeBytes => $composableBuilder(
    column: $table.sizeBytes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get contentId => $composableBuilder(
    column: $table.contentId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isInline => $composableBuilder(
    column: $table.isInline,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get localPath => $composableBuilder(
    column: $table.localPath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isOutgoing => $composableBuilder(
    column: $table.isOutgoing,
    builder: (column) => ColumnFilters(column),
  );

  $$MessagesTableFilterComposer get messageId {
    final $$MessagesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.messageId,
      referencedTable: $db.messages,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MessagesTableFilterComposer(
            $db: $db,
            $table: $db.messages,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$AttachmentsTableOrderingComposer
    extends Composer<_$AppDatabase, $AttachmentsTable> {
  $$AttachmentsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get partId => $composableBuilder(
    column: $table.partId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get fileName => $composableBuilder(
    column: $table.fileName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get mimeType => $composableBuilder(
    column: $table.mimeType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sizeBytes => $composableBuilder(
    column: $table.sizeBytes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get contentId => $composableBuilder(
    column: $table.contentId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isInline => $composableBuilder(
    column: $table.isInline,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get localPath => $composableBuilder(
    column: $table.localPath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isOutgoing => $composableBuilder(
    column: $table.isOutgoing,
    builder: (column) => ColumnOrderings(column),
  );

  $$MessagesTableOrderingComposer get messageId {
    final $$MessagesTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.messageId,
      referencedTable: $db.messages,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MessagesTableOrderingComposer(
            $db: $db,
            $table: $db.messages,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$AttachmentsTableAnnotationComposer
    extends Composer<_$AppDatabase, $AttachmentsTable> {
  $$AttachmentsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get partId =>
      $composableBuilder(column: $table.partId, builder: (column) => column);

  GeneratedColumn<String> get fileName =>
      $composableBuilder(column: $table.fileName, builder: (column) => column);

  GeneratedColumn<String> get mimeType =>
      $composableBuilder(column: $table.mimeType, builder: (column) => column);

  GeneratedColumn<int> get sizeBytes =>
      $composableBuilder(column: $table.sizeBytes, builder: (column) => column);

  GeneratedColumn<String> get contentId =>
      $composableBuilder(column: $table.contentId, builder: (column) => column);

  GeneratedColumn<bool> get isInline =>
      $composableBuilder(column: $table.isInline, builder: (column) => column);

  GeneratedColumn<String> get localPath =>
      $composableBuilder(column: $table.localPath, builder: (column) => column);

  GeneratedColumn<bool> get isOutgoing => $composableBuilder(
    column: $table.isOutgoing,
    builder: (column) => column,
  );

  $$MessagesTableAnnotationComposer get messageId {
    final $$MessagesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.messageId,
      referencedTable: $db.messages,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MessagesTableAnnotationComposer(
            $db: $db,
            $table: $db.messages,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$AttachmentsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $AttachmentsTable,
          AttachmentRow,
          $$AttachmentsTableFilterComposer,
          $$AttachmentsTableOrderingComposer,
          $$AttachmentsTableAnnotationComposer,
          $$AttachmentsTableCreateCompanionBuilder,
          $$AttachmentsTableUpdateCompanionBuilder,
          (AttachmentRow, $$AttachmentsTableReferences),
          AttachmentRow,
          PrefetchHooks Function({bool messageId})
        > {
  $$AttachmentsTableTableManager(_$AppDatabase db, $AttachmentsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AttachmentsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AttachmentsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AttachmentsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> messageId = const Value.absent(),
                Value<String> partId = const Value.absent(),
                Value<String> fileName = const Value.absent(),
                Value<String> mimeType = const Value.absent(),
                Value<int> sizeBytes = const Value.absent(),
                Value<String?> contentId = const Value.absent(),
                Value<bool> isInline = const Value.absent(),
                Value<String?> localPath = const Value.absent(),
                Value<bool> isOutgoing = const Value.absent(),
              }) => AttachmentsCompanion(
                id: id,
                messageId: messageId,
                partId: partId,
                fileName: fileName,
                mimeType: mimeType,
                sizeBytes: sizeBytes,
                contentId: contentId,
                isInline: isInline,
                localPath: localPath,
                isOutgoing: isOutgoing,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required int messageId,
                Value<String> partId = const Value.absent(),
                Value<String> fileName = const Value.absent(),
                Value<String> mimeType = const Value.absent(),
                Value<int> sizeBytes = const Value.absent(),
                Value<String?> contentId = const Value.absent(),
                Value<bool> isInline = const Value.absent(),
                Value<String?> localPath = const Value.absent(),
                Value<bool> isOutgoing = const Value.absent(),
              }) => AttachmentsCompanion.insert(
                id: id,
                messageId: messageId,
                partId: partId,
                fileName: fileName,
                mimeType: mimeType,
                sizeBytes: sizeBytes,
                contentId: contentId,
                isInline: isInline,
                localPath: localPath,
                isOutgoing: isOutgoing,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$AttachmentsTable, AttachmentRow>(table),
                  $$AttachmentsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({messageId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (messageId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.messageId,
                                referencedTable: $$AttachmentsTableReferences
                                    ._messageIdTable(db),
                                referencedColumn: $$AttachmentsTableReferences
                                    ._messageIdTable(db)
                                    .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$AttachmentsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $AttachmentsTable,
      AttachmentRow,
      $$AttachmentsTableFilterComposer,
      $$AttachmentsTableOrderingComposer,
      $$AttachmentsTableAnnotationComposer,
      $$AttachmentsTableCreateCompanionBuilder,
      $$AttachmentsTableUpdateCompanionBuilder,
      (AttachmentRow, $$AttachmentsTableReferences),
      AttachmentRow,
      PrefetchHooks Function({bool messageId})
    >;
typedef $$LabelsTableCreateCompanionBuilder =
    LabelsCompanion Function({
      Value<int> id,
      required int accountId,
      required String name,
      Value<int> toneIndex,
      Value<String?> imapKeyword,
    });
typedef $$LabelsTableUpdateCompanionBuilder =
    LabelsCompanion Function({
      Value<int> id,
      Value<int> accountId,
      Value<String> name,
      Value<int> toneIndex,
      Value<String?> imapKeyword,
    });

final class $$LabelsTableReferences
    extends BaseReferences<_$AppDatabase, $LabelsTable, LabelRow> {
  $$LabelsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $AccountsTable _accountIdTable(_$AppDatabase db) =>
      db.accounts.createAlias('labels__account_id__accounts__id');

  $$AccountsTableProcessedTableManager get accountId {
    final $_column = $_itemColumn<int>('account_id')!;

    final manager = $$AccountsTableTableManager(
      $_db,
      $_db.accounts,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_accountIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$LabelsTableFilterComposer
    extends Composer<_$AppDatabase, $LabelsTable> {
  $$LabelsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get toneIndex => $composableBuilder(
    column: $table.toneIndex,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get imapKeyword => $composableBuilder(
    column: $table.imapKeyword,
    builder: (column) => ColumnFilters(column),
  );

  $$AccountsTableFilterComposer get accountId {
    final $$AccountsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.accounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AccountsTableFilterComposer(
            $db: $db,
            $table: $db.accounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$LabelsTableOrderingComposer
    extends Composer<_$AppDatabase, $LabelsTable> {
  $$LabelsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get toneIndex => $composableBuilder(
    column: $table.toneIndex,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get imapKeyword => $composableBuilder(
    column: $table.imapKeyword,
    builder: (column) => ColumnOrderings(column),
  );

  $$AccountsTableOrderingComposer get accountId {
    final $$AccountsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.accounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AccountsTableOrderingComposer(
            $db: $db,
            $table: $db.accounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$LabelsTableAnnotationComposer
    extends Composer<_$AppDatabase, $LabelsTable> {
  $$LabelsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<int> get toneIndex =>
      $composableBuilder(column: $table.toneIndex, builder: (column) => column);

  GeneratedColumn<String> get imapKeyword => $composableBuilder(
    column: $table.imapKeyword,
    builder: (column) => column,
  );

  $$AccountsTableAnnotationComposer get accountId {
    final $$AccountsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.accounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AccountsTableAnnotationComposer(
            $db: $db,
            $table: $db.accounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$LabelsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $LabelsTable,
          LabelRow,
          $$LabelsTableFilterComposer,
          $$LabelsTableOrderingComposer,
          $$LabelsTableAnnotationComposer,
          $$LabelsTableCreateCompanionBuilder,
          $$LabelsTableUpdateCompanionBuilder,
          (LabelRow, $$LabelsTableReferences),
          LabelRow,
          PrefetchHooks Function({bool accountId})
        > {
  $$LabelsTableTableManager(_$AppDatabase db, $LabelsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LabelsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LabelsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LabelsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> accountId = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<int> toneIndex = const Value.absent(),
                Value<String?> imapKeyword = const Value.absent(),
              }) => LabelsCompanion(
                id: id,
                accountId: accountId,
                name: name,
                toneIndex: toneIndex,
                imapKeyword: imapKeyword,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required int accountId,
                required String name,
                Value<int> toneIndex = const Value.absent(),
                Value<String?> imapKeyword = const Value.absent(),
              }) => LabelsCompanion.insert(
                id: id,
                accountId: accountId,
                name: name,
                toneIndex: toneIndex,
                imapKeyword: imapKeyword,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$LabelsTable, LabelRow>(table),
                  $$LabelsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({accountId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (accountId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.accountId,
                                referencedTable: $$LabelsTableReferences
                                    ._accountIdTable(db),
                                referencedColumn: $$LabelsTableReferences
                                    ._accountIdTable(db)
                                    .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$LabelsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $LabelsTable,
      LabelRow,
      $$LabelsTableFilterComposer,
      $$LabelsTableOrderingComposer,
      $$LabelsTableAnnotationComposer,
      $$LabelsTableCreateCompanionBuilder,
      $$LabelsTableUpdateCompanionBuilder,
      (LabelRow, $$LabelsTableReferences),
      LabelRow,
      PrefetchHooks Function({bool accountId})
    >;
typedef $$PendingOperationsTableCreateCompanionBuilder =
    PendingOperationsCompanion Function({
      Value<int> id,
      required int accountId,
      required PendingOpType type,
      Value<String> payloadJson,
      Value<DateTime> createdAt,
      Value<int> attemptCount,
      Value<DateTime?> nextAttemptAt,
      Value<String?> lastError,
      Value<PendingOpStatus> status,
    });
typedef $$PendingOperationsTableUpdateCompanionBuilder =
    PendingOperationsCompanion Function({
      Value<int> id,
      Value<int> accountId,
      Value<PendingOpType> type,
      Value<String> payloadJson,
      Value<DateTime> createdAt,
      Value<int> attemptCount,
      Value<DateTime?> nextAttemptAt,
      Value<String?> lastError,
      Value<PendingOpStatus> status,
    });

final class $$PendingOperationsTableReferences
    extends
        BaseReferences<
          _$AppDatabase,
          $PendingOperationsTable,
          PendingOperationRow
        > {
  $$PendingOperationsTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $AccountsTable _accountIdTable(_$AppDatabase db) =>
      db.accounts.createAlias('pending_operations__account_id__accounts__id');

  $$AccountsTableProcessedTableManager get accountId {
    final $_column = $_itemColumn<int>('account_id')!;

    final manager = $$AccountsTableTableManager(
      $_db,
      $_db.accounts,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_accountIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$PendingOperationsTableFilterComposer
    extends Composer<_$AppDatabase, $PendingOperationsTable> {
  $$PendingOperationsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnWithTypeConverterFilters<PendingOpType, PendingOpType, int> get type =>
      $composableBuilder(
        column: $table.type,
        builder: (column) => ColumnWithTypeConverterFilters(column),
      );

  ColumnFilters<String> get payloadJson => $composableBuilder(
    column: $table.payloadJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get attemptCount => $composableBuilder(
    column: $table.attemptCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get nextAttemptAt => $composableBuilder(
    column: $table.nextAttemptAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get lastError => $composableBuilder(
    column: $table.lastError,
    builder: (column) => ColumnFilters(column),
  );

  ColumnWithTypeConverterFilters<PendingOpStatus, PendingOpStatus, int>
  get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnWithTypeConverterFilters(column),
  );

  $$AccountsTableFilterComposer get accountId {
    final $$AccountsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.accounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AccountsTableFilterComposer(
            $db: $db,
            $table: $db.accounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$PendingOperationsTableOrderingComposer
    extends Composer<_$AppDatabase, $PendingOperationsTable> {
  $$PendingOperationsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get payloadJson => $composableBuilder(
    column: $table.payloadJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get attemptCount => $composableBuilder(
    column: $table.attemptCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get nextAttemptAt => $composableBuilder(
    column: $table.nextAttemptAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get lastError => $composableBuilder(
    column: $table.lastError,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  $$AccountsTableOrderingComposer get accountId {
    final $$AccountsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.accounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AccountsTableOrderingComposer(
            $db: $db,
            $table: $db.accounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$PendingOperationsTableAnnotationComposer
    extends Composer<_$AppDatabase, $PendingOperationsTable> {
  $$PendingOperationsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumnWithTypeConverter<PendingOpType, int> get type =>
      $composableBuilder(column: $table.type, builder: (column) => column);

  GeneratedColumn<String> get payloadJson => $composableBuilder(
    column: $table.payloadJson,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get attemptCount => $composableBuilder(
    column: $table.attemptCount,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get nextAttemptAt => $composableBuilder(
    column: $table.nextAttemptAt,
    builder: (column) => column,
  );

  GeneratedColumn<String> get lastError =>
      $composableBuilder(column: $table.lastError, builder: (column) => column);

  GeneratedColumnWithTypeConverter<PendingOpStatus, int> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  $$AccountsTableAnnotationComposer get accountId {
    final $$AccountsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.accountId,
      referencedTable: $db.accounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AccountsTableAnnotationComposer(
            $db: $db,
            $table: $db.accounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$PendingOperationsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $PendingOperationsTable,
          PendingOperationRow,
          $$PendingOperationsTableFilterComposer,
          $$PendingOperationsTableOrderingComposer,
          $$PendingOperationsTableAnnotationComposer,
          $$PendingOperationsTableCreateCompanionBuilder,
          $$PendingOperationsTableUpdateCompanionBuilder,
          (PendingOperationRow, $$PendingOperationsTableReferences),
          PendingOperationRow,
          PrefetchHooks Function({bool accountId})
        > {
  $$PendingOperationsTableTableManager(
    _$AppDatabase db,
    $PendingOperationsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PendingOperationsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PendingOperationsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PendingOperationsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> accountId = const Value.absent(),
                Value<PendingOpType> type = const Value.absent(),
                Value<String> payloadJson = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<int> attemptCount = const Value.absent(),
                Value<DateTime?> nextAttemptAt = const Value.absent(),
                Value<String?> lastError = const Value.absent(),
                Value<PendingOpStatus> status = const Value.absent(),
              }) => PendingOperationsCompanion(
                id: id,
                accountId: accountId,
                type: type,
                payloadJson: payloadJson,
                createdAt: createdAt,
                attemptCount: attemptCount,
                nextAttemptAt: nextAttemptAt,
                lastError: lastError,
                status: status,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required int accountId,
                required PendingOpType type,
                Value<String> payloadJson = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<int> attemptCount = const Value.absent(),
                Value<DateTime?> nextAttemptAt = const Value.absent(),
                Value<String?> lastError = const Value.absent(),
                Value<PendingOpStatus> status = const Value.absent(),
              }) => PendingOperationsCompanion.insert(
                id: id,
                accountId: accountId,
                type: type,
                payloadJson: payloadJson,
                createdAt: createdAt,
                attemptCount: attemptCount,
                nextAttemptAt: nextAttemptAt,
                lastError: lastError,
                status: status,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$PendingOperationsTable, PendingOperationRow>(
                    table,
                  ),
                  $$PendingOperationsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({accountId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (accountId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.accountId,
                                referencedTable:
                                    $$PendingOperationsTableReferences
                                        ._accountIdTable(db),
                                referencedColumn:
                                    $$PendingOperationsTableReferences
                                        ._accountIdTable(db)
                                        .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$PendingOperationsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $PendingOperationsTable,
      PendingOperationRow,
      $$PendingOperationsTableFilterComposer,
      $$PendingOperationsTableOrderingComposer,
      $$PendingOperationsTableAnnotationComposer,
      $$PendingOperationsTableCreateCompanionBuilder,
      $$PendingOperationsTableUpdateCompanionBuilder,
      (PendingOperationRow, $$PendingOperationsTableReferences),
      PendingOperationRow,
      PrefetchHooks Function({bool accountId})
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$AccountsTableTableManager get accounts =>
      $$AccountsTableTableManager(_db, _db.accounts);
  $$MailboxesTableTableManager get mailboxes =>
      $$MailboxesTableTableManager(_db, _db.mailboxes);
  $$MessagesTableTableManager get messages =>
      $$MessagesTableTableManager(_db, _db.messages);
  $$MessageBodiesTableTableManager get messageBodies =>
      $$MessageBodiesTableTableManager(_db, _db.messageBodies);
  $$AttachmentsTableTableManager get attachments =>
      $$AttachmentsTableTableManager(_db, _db.attachments);
  $$LabelsTableTableManager get labels =>
      $$LabelsTableTableManager(_db, _db.labels);
  $$PendingOperationsTableTableManager get pendingOperations =>
      $$PendingOperationsTableTableManager(_db, _db.pendingOperations);
}
