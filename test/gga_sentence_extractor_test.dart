import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rtkmanager/gga_sentence_extractor.dart';

void main() {
  group('GgaSentenceExtractor', () {
    test('extracts GNGGA surrounded by binary data', () {
      final extractor = GgaSentenceExtractor();
      final sentence = _nmeaSentence(
        'GNGGA,123519.00,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,',
      );

      final result = extractor.add([
        0xd3,
        0x00,
        0x13,
        0xff,
        ...ascii.encode(sentence),
        0x00,
        0x80,
        0xd3,
      ]);

      expect(result, [sentence]);
    });

    test('extracts a GNGGA sentence split across chunks', () {
      final extractor = GgaSentenceExtractor();
      final sentence = _nmeaSentence(
        'GNGGA,123520.00,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,',
      );
      final checksumIndex = sentence.indexOf('*');

      expect(
        extractor.add([0xfe, 0x01, ...ascii.encode(sentence.substring(0, 4))]),
        isEmpty,
      );
      expect(
        extractor.add(ascii.encode(sentence.substring(4, checksumIndex + 2))),
        isEmpty,
      );
      expect(
        extractor.add([
          ...ascii.encode(sentence.substring(checksumIndex + 2)),
          0x00,
          0xff,
        ]),
        [sentence],
      );
    });

    test(
      'recovers from an incomplete sentence and extracts later GGA data',
      () {
        final extractor = GgaSentenceExtractor();
        final gngga = _nmeaSentence(
          'GNGGA,123521.00,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,',
        );
        final gpgga = _nmeaSentence(
          'GPGGA,123522.00,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,',
        );

        final result = extractor.add([
          ...ascii.encode(r'$GNGGA,incomplete'),
          0x00,
          0xfe,
          ...ascii.encode(gngga),
          0xd3,
          0x00,
          ...ascii.encode(gpgga),
        ]);

        expect(result, [gngga, gpgga]);
      },
    );
  });
}

String _nmeaSentence(String body) {
  var checksum = 0;
  for (final byte in ascii.encode(body)) {
    checksum ^= byte;
  }
  return '\$$body*${checksum.toRadixString(16).toUpperCase().padLeft(2, '0')}';
}
