import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/avatar.dart';
import '../../../core/turkish.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// Gönderen avatarı.
///
/// Renk, e-posta adresinin FNV-1a özetinden seçilir: aynı kişi her zaman
/// aynı rengi alır. Seçiliyken vurgu dolgusuna ve onay ikonuna döner.
class KaydetAvatar extends StatelessWidget {
  const KaydetAvatar({
    super.key,
    required this.name,
    required this.email,
    this.isSelected = false,
    this.size = Dimens.avatarSize,
    this.onTap,
  });

  final String? name;
  final String? email;
  final bool isSelected;
  final double size;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final tone = t.toneAt(
      AvatarHash.toneIndex(email, name, t.avatarTones.length),
    );
    final initial = avatarInitial(name, email);

    final avatar = AnimatedContainer(
      duration: context.motion(Motion.fast),
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: isSelected ? t.accentFill : tone.background,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: isSelected
          ? Icon(LucideIcons.check, size: size * 0.45, color: t.onAccentFill)
          : Text(
              initial,
              style: TextStyle(
                color: tone.foreground,
                fontSize: size * 0.38,
                fontWeight: FontWeight.w600,
                height: 1,
              ),
            ),
    );

    if (onTap == null) return avatar;

    // Dokunma alanı 48 dp'ye genişletilir (Android erişilebilirlik alt sınırı).
    return Semantics(
      button: true,
      label: isSelected ? 'Seçimi kaldır' : 'Seç',
      child: InkResponse(
        onTap: onTap,
        radius: Dimens.touchTarget / 2,
        containedInkWell: false,
        child: SizedBox(
          width: Dimens.touchTarget,
          height: Dimens.touchTarget,
          child: Center(child: avatar),
        ),
      ),
    );
  }
}

/// Gönderen avatarı — tanınan marka alan adları için gerçek logo gösterir.
///
/// Kişisel e-posta sağlayıcılarında (Gmail, Outlook, …) ve seçili
/// durumdayken her zaman [KaydetAvatar]'a düşer: aksi hâlde herkes aynı
/// sağlayıcı logosunu alır ya da seçim ikonu logonun altında kalır. Logo
/// yüklenemezse (ağ yok, alan adının favicon'u yok) de sessizce aynı
/// düz renkli baş harfe döner — hiçbir durumda boş/bozuk görsel kalmaz.
class BrandAvatar extends StatelessWidget {
  const BrandAvatar({
    super.key,
    required this.name,
    required this.email,
    this.isSelected = false,
    this.size = Dimens.avatarSize,
    this.onTap,
  });

  final String? name;
  final String? email;
  final bool isSelected;
  final double size;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final domain = domainOf(email);
    if (isSelected ||
        domain == null ||
        PersonalEmailDomains.isPersonal(domain)) {
      return KaydetAvatar(
        name: name,
        email: email,
        isSelected: isSelected,
        size: size,
        onTap: onTap,
      );
    }

    final logo = ClipOval(
      child: Container(
        width: size,
        height: size,
        color: Colors.white,
        padding: EdgeInsets.all(size * 0.16),
        child: CachedNetworkImage(
          imageUrl: 'https://www.google.com/s2/favicons?domain=$domain&sz=128',
          fit: BoxFit.contain,
          fadeInDuration: Duration.zero,
          memCacheWidth: (size * 2).round(),
          errorWidget: (_, _, _) =>
              KaydetAvatar(name: name, email: email, size: size),
          placeholder: (_, _) =>
              KaydetAvatar(name: name, email: email, size: size),
        ),
      ),
    );

    if (onTap == null) return logo;
    return Semantics(
      button: true,
      label: 'Seç',
      child: InkResponse(
        onTap: onTap,
        radius: Dimens.touchTarget / 2,
        containedInkWell: false,
        child: SizedBox(
          width: Dimens.touchTarget,
          height: Dimens.touchTarget,
          child: Center(child: logo),
        ),
      ),
    );
  }
}

/// "Hızlı Kişiler" şeridindeki bir kişi: Outlook'taki gibi büyük avatar,
/// altında ilk sözcük üst satırda ve kalanı (kısaltılarak) alt satırda ad.
/// Adı olmayan kişide e-posta adresi tek satırda kalır.
///
/// Şerit hem arama ekranında (dokununca aranır) hem yazma ekranında
/// (dokununca alıcı eklenir) aynı görünümdedir; ne olacağını çağıran verir.
class QuickContactAvatar extends StatelessWidget {
  const QuickContactAvatar({
    super.key,
    required this.name,
    required this.email,
    required this.onTap,
  });

  final String name;
  final String email;
  final VoidCallback onTap;

  static const double _avatarSize = 40;
  static const double _width = 54;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final label = name.trim().isNotEmpty ? name.trim() : email;
    final split = label.indexOf(RegExp(r'\s'));
    final firstLine = split < 0 ? label : label.substring(0, split);
    final secondLine = split < 0 ? '' : label.substring(split).trim();

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Radii.md),
      child: SizedBox(
        width: _width,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            BrandAvatar(name: name, email: email, size: _avatarSize),
            const SizedBox(height: Space.xs),
            Text(
              firstLine,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: AppText.labelMedium.copyWith(color: t.textPrimary),
            ),
            if (secondLine.isNotEmpty)
              Text(
                secondLine,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: AppText.labelMedium.copyWith(color: t.textSecondary),
              ),
          ],
        ),
      ),
    );
  }
}

/// Etiket rozeti.
class LabelChip extends StatelessWidget {
  const LabelChip({
    super.key,
    required this.name,
    required this.toneIndex,
    this.onDeleted,
  });

  final String name;
  final int toneIndex;
  final VoidCallback? onDeleted;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final tone = t.toneAt(toneIndex);
    return Container(
      padding: EdgeInsets.only(
        left: Space.sm,
        right: onDeleted == null ? Space.sm : Space.xs,
        top: 2,
        bottom: 2,
      ),
      decoration: BoxDecoration(
        color: tone.background,
        borderRadius: BorderRadius.circular(Radii.xs),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            name,
            style: TextStyle(
              color: tone.foreground,
              fontSize: 11 * AppText.scale,
              fontWeight: FontWeight.w600,
              height: 14 / 11,
            ),
          ),
          if (onDeleted != null) ...[
            const SizedBox(width: Space.xs),
            GestureDetector(
              onTap: onDeleted,
              child: Icon(LucideIcons.x, size: 12, color: tone.foreground),
            ),
          ],
        ],
      ),
    );
  }
}

/// Boş durum ekranı.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.description,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? description;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Space.xxxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: t.textTertiary),
            const SizedBox(height: Space.lg),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (description != null) ...[
              const SizedBox(height: Space.sm),
              Text(
                description!,
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: t.textSecondary),
              ),
            ],
            if (action != null) ...[const SizedBox(height: Space.xl), action!],
          ],
        ),
      ),
    );
  }
}

/// Çevrimdışı / hata şeridi.
class StatusBanner extends StatelessWidget {
  const StatusBanner({
    super.key,
    required this.message,
    required this.icon,
    this.color,
    this.onAction,
    this.actionLabel,
  });

  final String message;
  final IconData icon;
  final Color? color;
  final VoidCallback? onAction;
  final String? actionLabel;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final tint = color ?? t.warning;
    return Material(
      color: t.surface,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Space.lg,
          vertical: Space.sm,
        ),
        child: Row(
          children: [
            Icon(icon, size: IconSize.sm, color: tint),
            const SizedBox(width: Space.sm),
            Expanded(
              child: Text(
                message,
                style: Theme.of(
                  context,
                ).textTheme.labelMedium?.copyWith(color: t.textSecondary),
              ),
            ),
            if (onAction != null && actionLabel != null)
              TextButton(
                onPressed: onAction,
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 32),
                  padding: const EdgeInsets.symmetric(horizontal: Space.sm),
                ),
                child: Text(actionLabel!),
              ),
          ],
        ),
      ),
    );
  }
}

/// Bölüm başlığı.
class SectionHeader extends StatelessWidget {
  const SectionHeader(
    this.title, {
    super.key,
    this.trailing,
    this.showDivider = false,
  });

  final String title;
  final Widget? trailing;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        Space.lg,
        showDivider ? Space.lg : Space.xl,
        Space.sm,
        showDivider ? Space.xs : Space.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: t.textTertiary,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
          if (showDivider)
            const Divider(height: Space.md, thickness: Dimens.dividerThickness),
        ],
      ),
    );
  }
}

/// Ayarlar satırı.
class SettingsTile extends StatelessWidget {
  const SettingsTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.isDestructive = false,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool isDestructive;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final color = isDestructive ? t.danger : t.textPrimary;
    return InkWell(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: Dimens.touchTarget + 8),
        padding: const EdgeInsets.symmetric(
          horizontal: Space.lg,
          vertical: Space.md,
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: IconSize.md,
              color: isDestructive ? t.danger : t.textSecondary,
            ),
            const SizedBox(width: Space.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: color,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: Theme.of(
                        context,
                      ).textTheme.labelSmall?.copyWith(color: t.textTertiary),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) const SizedBox(width: Space.md),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

/// Kart benzeri gruplama kutusu.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: Space.lg),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: t.divider),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) Divider(height: 1, color: t.divider),
            children[i],
          ],
        ],
      ),
    );
  }
}

/// Standart iki eylemli onay diyaloğu düğme çifti: solda içi boş
/// (`OutlinedButton`) düşük taahhütlü eylem, sağda dolu (`FilledButton`)
/// asıl eylem. `AlertDialog.actions`'a TEK öğe olarak verilip
/// `actionsAlignment: MainAxisAlignment.center` ile ortalanmalıdır.
///
/// Neden gerekli: Uygulama genelindeki `FilledButton` teması tam genişlik
/// ister (`app_theme.dart` → `Size.fromHeight(Dimens.controlHeight)`) —
/// bu, giriş/gönder gibi tek başına duran birincil eylemler için doğrudur.
/// Ama bir onay diyaloğunda iki düğme yan yana dururken sonsuz genişlik
/// istemek, `AlertDialog`'un yerleşik `OverflowBar`'ını satırın ekrana
/// sığmadığını sanıp alt alta dizmeye zorluyordu: bir düğme köşede küçük
/// kalıp diğeri satırı tek başına, kenardan kenara tam genişlikte
/// kaplıyordu. Burada her iki düğmenin genişliği içeriğine göre
/// sınırlanır ve ikisi tek bir birim olarak ortalanır.
class DialogActions extends StatelessWidget {
  const DialogActions({
    super.key,
    required this.cancelLabel,
    required this.onCancel,
    required this.confirmLabel,
    required this.onConfirm,
    this.destructive = false,
  });

  final String cancelLabel;
  final VoidCallback onCancel;
  final String confirmLabel;
  final VoidCallback onConfirm;

  /// Onay eylemi yıkıcıysa (sil, çıkış yap vb.) düğme kırmızı dolgu alır.
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    const minSize = Size(0, Dimens.controlHeight);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        OutlinedButton(
          onPressed: onCancel,
          style: OutlinedButton.styleFrom(minimumSize: minSize),
          child: Text(cancelLabel),
        ),
        const SizedBox(width: Space.sm),
        FilledButton(
          onPressed: onConfirm,
          style: FilledButton.styleFrom(
            minimumSize: minSize,
            backgroundColor: destructive ? t.dangerFill : null,
          ),
          child: Text(confirmLabel),
        ),
      ],
    );
  }
}

/// Standart iki eylemli onay diyaloğu — `DialogActions`ı `AlertDialog` içine
/// sarıp sonucu döndürür. Ayarlar hiyerarşisindeki birden fazla alt sayfa
/// (hesap silme, önbellek temizleme, çöp kutusunu boşaltma) aynı diyaloğu
/// kullandığı için paylaşılan bir yardımcıya taşındı.
Future<bool?> confirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  bool destructive = false,
}) => showDialog<bool>(
  context: context,
  builder: (context) => AlertDialog(
    title: Text(title),
    content: Text(message),
    actionsAlignment: MainAxisAlignment.center,
    actions: [
      DialogActions(
        cancelLabel: 'Vazgeç',
        onCancel: () => Navigator.of(context).pop(false),
        confirmLabel: confirmLabel,
        onConfirm: () => Navigator.of(context).pop(true),
        destructive: destructive,
      ),
    ],
  ),
);

/// Herhangi bir iskelet şeklinin üzerinde soldan sağa kayan, sürekli
/// tekrarlanan bir parlaklık bandı oynatır.
///
/// Şeklin kendisini bilmez — `child` düz renkli kutu/daire gibi opak
/// şekillerden oluşan HERHANGİ bir iskelet olabilir (mail gövdesindeki
/// paragraf çizgileri, liste satırındaki avatar+iki satır düzeni gibi);
/// `ShaderMask` + `BlendMode.srcIn` yalnızca o şekillerin ALFA'sını maske
/// olarak kullanıp rengini gradyanla değiştirir. Hem `MailDetailScreen`
/// hem `MailListScreen`'in iskeletleri aynı mekanizmayı paylaşır.
class ShimmerSurface extends StatefulWidget {
  const ShimmerSurface({super.key, required this.child});

  final Widget child;

  @override
  State<ShimmerSurface> createState() => _ShimmerSurfaceState();
}

class _ShimmerSurfaceState extends State<ShimmerSurface>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final base = t.surface;
    final highlight = t.surfaceElevated;

    return AnimatedBuilder(
      animation: _controller,
      // `child` sabit tutulur: her animasyon karesinde yeniden kurulan AYNI
      // iskelet widget'ları, yalnızca üstlerindeki gradyan kayar.
      child: widget.child,
      builder: (context, child) => ShaderMask(
        blendMode: BlendMode.srcIn,
        shaderCallback: (bounds) {
          final v = _controller.value;
          return LinearGradient(
            colors: [base, base, highlight, base, base],
            stops: const [0.0, 0.35, 0.5, 0.65, 1.0],
            begin: Alignment(-3 + 4 * v, 0),
            end: Alignment(-1 + 4 * v, 0),
          ).createShader(bounds);
        },
        child: child,
      ),
    );
  }
}

/// Tek bir iskelet satırı — yuvarlatılmış köşeli, düz renkli bir bar.
///
/// `widthFactor` verilirse (metin satırları gibi değişen genişlikte
/// görünmesi istenen yerlerde) çevresindeki alana oranla; `width` verilirse
/// sabit piksel genişliğinde çizilir.
class ShimmerBar extends StatelessWidget {
  const ShimmerBar({super.key, this.width, this.widthFactor, this.height = 14});

  final double? width;
  final double? widthFactor;
  final double height;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final bar = Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
    );
    if (widthFactor == null) return bar;
    return FractionallySizedBox(widthFactor: widthFactor, child: bar);
  }
}
