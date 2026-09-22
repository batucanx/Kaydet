import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'tokens.dart';

/// Tipografi rolleri — `docs/plan/04-tasarim-sistemi.md` §4.5
abstract final class AppText {
  static const String family = 'Satoshi';

  /// Tüm yazı boyutlarının ortak çarpanı — kullanıcı isteğiyle uygulama
  /// genelinde bir miktar büyütüldü. Aşağıdaki rol boyutları tasarım
  /// belgesindeki özgün değerleriyle yazılıdır; bütün ölçeği tek yerden
  /// ayarlamak için yalnızca bu sabit değiştirilir. Rollerin dışında elle
  /// yazılan `fontSize` değerleri de aynı çarpana bağlıdır (`N * AppText.scale`).
  /// Satır aralıkları oran (`height`) olarak verildiğinden birlikte ölçeklenir.
  static const double scale = 1.1;

  static const TextStyle titleLarge = TextStyle(
    fontFamily: family,
    fontSize: 18 * scale,
    height: 24 / 18,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.2,
  );

  static const TextStyle titleMedium = TextStyle(
    fontFamily: family,
    fontSize: 15 * scale,
    height: 20 / 15,
    fontWeight: FontWeight.w600,
  );

  /// Mail gövdesi — Outlook'un okuma bölmesindeki 12 pt'nin karşılığı,
  /// ferah satır aralığıyla (1.5).
  static const TextStyle bodyLarge = TextStyle(
    fontFamily: family,
    fontSize: 16 * scale,
    height: 1.5,
    fontWeight: FontWeight.w400,
  );

  static const TextStyle bodyMedium = TextStyle(
    fontFamily: family,
    fontSize: 13 * scale,
    height: 18 / 13,
    fontWeight: FontWeight.w400,
  );

  // Liste satırları — kullanıcı isteğiyle sıkılaştırıldı: tek ekranda daha
  // fazla ileti görünsün diye Outlook'un "ferah" ölçeğinden küçültüldü
  // (bkz. `Dimens.listRowMinHeight`'daki eşleşen satır yüksekliği).
  static const TextStyle listSenderRead = TextStyle(
    fontFamily: family,
    fontSize: 14 * scale,
    height: 18 / 14,
    fontWeight: FontWeight.w500,
  );

  static const TextStyle listSenderUnread = TextStyle(
    fontFamily: family,
    fontSize: 14 * scale,
    height: 18 / 14,
    fontWeight: FontWeight.w700,
  );

  static const TextStyle listSubjectRead = TextStyle(
    fontFamily: family,
    fontSize: 13 * scale,
    height: 18 / 13,
    fontWeight: FontWeight.w400,
  );

  static const TextStyle listSubjectUnread = TextStyle(
    fontFamily: family,
    fontSize: 13 * scale,
    height: 18 / 13,
    fontWeight: FontWeight.w600,
  );

  static const TextStyle listPreview = TextStyle(
    fontFamily: family,
    fontSize: 12 * scale,
    height: 16 / 12,
    fontWeight: FontWeight.w400,
  );

  static const TextStyle labelMedium = TextStyle(
    fontFamily: family,
    fontSize: 11 * scale,
    height: 15 / 11,
    fontWeight: FontWeight.w600,
  );

  static const TextStyle labelSmall = TextStyle(
    fontFamily: family,
    fontSize: 10.5 * scale,
    height: 13 / 10.5,
    fontWeight: FontWeight.w600,
  );

  static const TextStyle overline = TextStyle(
    fontFamily: family,
    fontSize: 9.5 * scale,
    height: 13 / 9.5,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.8,
  );
}

abstract final class AppTheme {
  static ThemeData dark() => _build(KaydetTokens.dark);
  static ThemeData light() => _build(KaydetTokens.light);
  static ThemeData outlookDark() => _build(KaydetTokens.outlookDark);

  static ThemeData _build(KaydetTokens t) {
    final isDark = t.isDark;

    final colorScheme = ColorScheme(
      brightness: t.brightness,
      primary: t.accentFill,
      onPrimary: t.onAccentFill,
      secondary: t.accent,
      onSecondary: t.onAccentFill,
      error: t.dangerFill,
      onError: Colors.white,
      surface: t.bg,
      onSurface: t.textPrimary,
      surfaceContainerHighest: t.surfaceElevated,
      outline: t.border,
      outlineVariant: t.divider,
      scrim: t.scrim,
    );

    final textTheme = TextTheme(
      titleLarge: AppText.titleLarge.copyWith(color: t.textPrimary),
      titleMedium: AppText.titleMedium.copyWith(color: t.textPrimary),
      bodyLarge: AppText.bodyLarge.copyWith(color: t.textPrimary),
      bodyMedium: AppText.bodyMedium.copyWith(color: t.textPrimary),
      bodySmall: AppText.listPreview.copyWith(color: t.textTertiary),
      labelLarge: AppText.labelMedium.copyWith(color: t.textPrimary),
      labelMedium: AppText.labelMedium.copyWith(color: t.textSecondary),
      labelSmall: AppText.labelSmall.copyWith(color: t.textTertiary),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: t.brightness,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: t.bg,
      canvasColor: t.bg,
      fontFamily: AppText.family,
      textTheme: textTheme,
      extensions: [t],
      splashFactory: InkSparkle.splashFactory,
      appBarTheme: AppBarTheme(
        backgroundColor: t.appBarBg,
        foregroundColor: t.textPrimary,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        toolbarHeight: Dimens.appBarHeight,
        titleTextStyle: AppText.titleMedium.copyWith(color: t.textPrimary),
        systemOverlayStyle: isDark
            ? SystemUiOverlayStyle.light.copyWith(
                statusBarColor: Colors.transparent,
                systemNavigationBarColor: t.surfaceElevated,
                systemNavigationBarIconBrightness: Brightness.light,
              )
            : SystemUiOverlayStyle.dark.copyWith(
                statusBarColor: Colors.transparent,
                systemNavigationBarColor: t.surface,
                systemNavigationBarIconBrightness: Brightness.dark,
              ),
      ),
      dividerTheme: DividerThemeData(
        color: t.divider,
        thickness: Dimens.dividerThickness,
        space: Dimens.dividerThickness,
      ),
      iconTheme: IconThemeData(color: t.textSecondary, size: IconSize.md),
      listTileTheme: ListTileThemeData(
        iconColor: t.textSecondary,
        textColor: t.textPrimary,
        selectedColor: t.accent,
        minVerticalPadding: Space.md,
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: t.accentFill,
        foregroundColor: t.onAccentFill,
        elevation: isDark ? 0 : 3,
        focusElevation: isDark ? 0 : 4,
        hoverElevation: isDark ? 0 : 4,
        highlightElevation: isDark ? 0 : 6,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.lg),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: t.accentFill,
          foregroundColor: t.onAccentFill,
          disabledBackgroundColor: t.border,
          disabledForegroundColor: t.textTertiary,
          minimumSize: const Size.fromHeight(Dimens.controlHeight),
          textStyle: AppText.labelMedium.copyWith(fontSize: 14 * AppText.scale),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.md),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: t.textPrimary,
          side: BorderSide(color: t.border),
          minimumSize: const Size.fromHeight(Dimens.controlHeight),
          textStyle: AppText.labelMedium.copyWith(fontSize: 14 * AppText.scale),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.md),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: t.accent,
          textStyle: AppText.labelMedium.copyWith(fontSize: 14 * AppText.scale),
          minimumSize: const Size(Dimens.touchTarget, Dimens.touchTarget),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: t.surface,
        hintStyle: AppText.bodyMedium.copyWith(color: t.textTertiary),
        labelStyle: AppText.labelSmall.copyWith(color: t.textSecondary),
        errorStyle: AppText.labelSmall.copyWith(color: t.danger),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: Space.md,
          vertical: Space.md,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.sm + 2),
          borderSide: BorderSide(color: t.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.sm + 2),
          borderSide: BorderSide(color: t.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.sm + 2),
          borderSide: BorderSide(color: t.accent, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.sm + 2),
          borderSide: BorderSide(color: t.danger),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.sm + 2),
          borderSide: BorderSide(color: t.danger, width: 1.5),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: t.surfaceElevated,
        surfaceTintColor: Colors.transparent,
        elevation: isDark ? 0 : 8,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.lg),
        ),
        titleTextStyle: AppText.titleMedium.copyWith(color: t.textPrimary),
        contentTextStyle: AppText.bodyMedium.copyWith(color: t.textSecondary),
        // Tüm onay diyaloglarında tutarlı, ferah buton boşluğu — tek tek
        // her `AlertDialog`da elle ayarlamak yerine burada bir kez.
        actionsPadding: const EdgeInsets.fromLTRB(
          Space.lg,
          0,
          Space.lg,
          Space.md,
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: t.surfaceElevated,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.xl)),
        ),
        showDragHandle: true,
        dragHandleColor: t.border,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: t.surfaceElevated,
        contentTextStyle: AppText.bodyMedium.copyWith(color: t.textPrimary),
        actionTextColor: t.accent,
        behavior: SnackBarBehavior.floating,
        elevation: isDark ? 0 : 4,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.md),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? t.onAccentFill
              : t.textTertiary,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? t.accentFill : t.surface,
        ),
        trackOutlineColor: WidgetStateProperty.all(t.border),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? t.accentFill
              : Colors.transparent,
        ),
        checkColor: WidgetStateProperty.all(t.onAccentFill),
        side: BorderSide(color: t.border, width: 1.5),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: t.accent,
        linearTrackColor: t.surface,
        circularTrackColor: Colors.transparent,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: t.surfaceElevated,
        surfaceTintColor: Colors.transparent,
        indicatorColor: Colors.transparent,
        height: Dimens.bottomNavHeight,
        elevation: 0,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? AppText.labelSmall.copyWith(color: t.accent)
              : AppText.labelSmall.copyWith(
                  color: t.textTertiary,
                  fontWeight: FontWeight.w500,
                ),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            size: IconSize.md,
            color: states.contains(WidgetState.selected)
                ? t.accent
                : t.textTertiary,
          ),
        ),
      ),
      // Yalnızca Android geçişi özelleştirilir; `builders` haritası
      // varsayılanların TAMAMININ yerini alır (birleştirilmez) — iOS/macOS
      // burada elenirse platform kendi doğal Cupertino geçişini (ve
      // kenardan kaydırarak geri gitme jestini) kaybedip Android'in
      // Zoom-geçişine düşer; bu yüzden iOS/macOS varsayılanları da
      // açıkça korunur.
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
        },
      ),
    );
  }
}
