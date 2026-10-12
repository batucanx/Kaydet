import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/data/services/eml_parser_service.dart';

void main() {
  group('EML üstbilgi dayanıklılığı', () {
    test('açılı ayraçsız gönderen adresi bölünmez', () {
      final m = EmlParserService.parseText(
        'From: a@x.com\r\nTo: b@x.com\r\nSubject: S\r\n\r\nGövde',
      );
      expect(m.from.email, 'a@x.com');
      expect(m.from.name, 'a@x.com');
      expect(m.subject, 'S');
    });

    test('satır sonları silinmiş üstbilgiler geri ayrılır', () {
      final m = EmlParserService.parseText(
        'From: Ali <a@x.com>To: b@x.comSubject: MerhabaDate: Mon, 30 Sep 2026 10:00:00 +0300'
        'Content-Type: text/plain\r\n\r\nSelam',
      );
      expect(m.from.email, 'a@x.com');
      expect(m.from.name, 'Ali');
      expect(m.to.map((a) => a.email), ['b@x.com']);
      expect(m.subject, 'Merhaba');
      expect(m.textBody?.trim(), 'Selam');
    });

    test('BOM ve yalnız LF/CR satır sonları', () {
      final m = EmlParserService.parseText(
        '﻿From: A <a@x.com>\rSubject: Hi\r\rHello',
      );
      expect(m.from.email, 'a@x.com');
      expect(m.subject, 'Hi');
      expect(m.textBody?.trim(), 'Hello');
    });

    test('tırnaklı virgüllü adlar ve çoklu alıcı/CC', () {
      final m = EmlParserService.parseText(
        'From: "Doe, John" <j@x.com>\r\n'
        'To: a@x.com, "B, C" <c@x.com>\r\n'
        'Cc: d@x.com\r\n'
        'Subject: =?UTF-8?B?w4dhbMSxxZ9tYQ==?=\r\n\r\nbody',
      );
      expect(m.from.name, 'Doe, John');
      expect(m.to.map((a) => a.email), ['a@x.com', 'c@x.com']);
      expect(m.to.last.name, 'B, C');
      expect(m.cc.single.email, 'd@x.com');
      expect(m.subject, 'Çalışma');
    });

    test('multipart/alternative: base64 düz metin + HTML', () {
      final m = EmlParserService.parseText(
        'From: a@x.com\r\nSubject: H\r\n'
        'Content-Type: multipart/alternative; boundary="b1"\r\n\r\n'
        '--b1\r\nContent-Type: text/plain; charset=utf-8\r\n'
        'Content-Transfer-Encoding: base64\r\n\r\n'
        '${base64.encode(utf8.encode('düz'))}\r\n'
        '--b1\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<b>html</b>\r\n'
        '--b1--\r\n',
      );
      expect(m.textBody?.trim(), 'düz');
      expect(m.htmlBody, contains('<b>html</b>'));
    });

    test('Ekran Görüntüsü 1 Regresyon: t5 glued CTE and boundaries', () {
      const raw = '''
X-Mailer: KaydetMail
From: "=?utf8?Q?=C4=B0nfo?=" <info@pazarlik.com.tr>
To: "=?utf8?Q?
=C4=B0nfo_ha=C5=9Fem_=C5=9Fahan?=" <info@pazarlik.com.tr>,
info@denizliemlak.com
Date: Tue, 06 Oct 2026 16:53:45 +0300Message-Id: <a5bd4357-9169-e946-988d-7c3002fa75bf@pazarlik.com.tr>
Subject: t5
MIME-Version: 1.0
Content-Type: multipart/alternative; boundary="tBxHeOogUFzSKxgR3Q"--tBxHeOogUFzSKxgR3Q
Content-Type: text/plain; charset="utf-8"
Content-Transfer-Encoding: 7bitt5--tBxHeOogUFzSKxgR3Q
Content-Type: text/html; charset="utf-8"
Content-Transfer-Encoding: 7bit<p>t5</p>--tBxHeOogUFzSKxgR3Q--
''';

      final m = EmlParserService.parseText(raw);
      expect(m.subject, 't5');
      expect(m.from.email, 'info@pazarlik.com.tr');
      expect(m.from.name, 'İnfo');
      expect(m.to.any((a) => a.email == 'info@pazarlik.com.tr'), isTrue);
      expect(m.to.any((a) => a.email == 'info@denizliemlak.com'), isTrue);
      expect(m.htmlBody, contains('<p>t5</p>'));
      expect(m.textBody, contains('t5'));
      // Gövdede başlık bilgileri sızmamalı
      expect(m.textBody, isNot(contains('Content-Transfer-Encoding')));
      expect(m.textBody, isNot(contains('X-Mailer')));
      expect(m.textBody, isNot(contains('MIME-Version')));
    });

    test('Ekran Görüntüsü 2 Regresyon: Konusuz çökmüş transport başlıkları', () {
      const raw =
          'Return-Path: <nisatuurk@gmail.com>Delivered-To: info@pazarlik.com.tr'
          'Received: from host114.ni.net.tr by host114.ni.net.tr with LMTP id RY48Fm0zsmrsVC4ArkCfXQ (envelope-from <nisatuurk@gmail.com>) for <info@pazarlik.com.tr>; Tue, 22 Sep 2026 10:51:09 +0300'
          'Return-path: <nisatuurk@gmail.com>Envelope-to: info@pazarlik.com.tr'
          'Delivery-date: Tue, 22 Sep 2026 10:51:09 +0300'
          'Received: from mail-oa2-f12.google.com ([74.125.231.76]:45517) by host114.ni.net.tr with esmtps (TLS1.3) tls TLS_AES_128_GCM_SHA256 (Exim 4.100) (envelope-from <nisatuurk@gmail.com>) id 1x8vHC-0000000Cjib-1Jgh for info@pazarlik.com.tr; Tue, 22 Sep 2026 10:51:09 +0300'
          'ARC-Seal: i=1; a=rsa-sha256; t=1790063426; cv=none; d=google.com; s=arc-20260327; b=dummyseal123'
          'From: nisa türk <nisatuurk@gmail.com>'
          'To: info@pazarlik.com.tr'
          'Subject: Konusuz'
          'Date: Tue, 22 Sep 2026 13:50:00 +0300'
          'Content-Type: text/plain; charset=utf-8\r\n\r\n'
          'Merhaba, iletilen ek gövdesidir.';

      final m = EmlParserService.parseText(raw);
      expect(m.subject, 'Konusuz');
      expect(m.from.email, 'nisatuurk@gmail.com');
      expect(m.from.name, 'nisa türk');
      expect(m.to.first.email, 'info@pazarlik.com.tr');
      expect(m.textBody, contains('Merhaba, iletilen ek gövdesidir.'));
      // Gövdede Return-Path, Received, ARC-Seal sızmamalı
      expect(m.textBody, isNot(contains('Return-Path:')));
      expect(m.textBody, isNot(contains('Delivered-To:')));
      expect(m.textBody, isNot(contains('Received:')));
      expect(m.textBody, isNot(contains('ARC-Seal:')));
    });
  });
}
