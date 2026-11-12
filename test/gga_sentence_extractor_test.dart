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

    test('extracts GBGGA from mixed binary and ASCII data', () {
      final extractor = GgaSentenceExtractor();
      final sentence = _nmeaSentence(
        'GBGGA,123520.00,4807.038,N,01131.000,E,4,18,0.9,545.4,M,46.9,M,,',
      );
      final otherSentence = _nmeaSentence('GBGSV,1,1,00');

      final result = extractor.add([
        0xd3,
        0x00,
        0xff,
        ...ascii.encode('$otherSentence\r\n'),
        0x80,
        0x24,
        0x00,
        ...ascii.encode(sentence),
        0x00,
        0xff,
        ...ascii.encode('\r\n$otherSentence\r\n'),
      ]);

      expect(result, [sentence]);
    });

    test('extracts GBGGA at every possible chunk boundary', () {
      final sentence = _nmeaSentence(
        'GBGGA,123520.00,4807.038,N,01131.000,E,4,18,0.9,545.4,M,46.9,M,,',
      );
      final bytes = ascii.encode(sentence);

      for (var split = 1; split < bytes.length; split++) {
        final extractor = GgaSentenceExtractor();

        expect(
          extractor.add([0xd3, 0x00, 0xff, ...bytes.sublist(0, split)]),
          isEmpty,
          reason: 'Incomplete sentence at byte $split',
        );
        expect(
          extractor.add([...bytes.sublist(split), 0x00, 0x80]),
          [sentence],
          reason: 'Sentence split at byte $split',
        );
        expect(extractor.add([]), isEmpty);
      }
    });

    test('extracts adjacent GNGGA, GBGGA and GPGGA without line endings', () {
      final extractor = GgaSentenceExtractor();
      final sentences = [
        for (final talker in ['GN', 'GB', 'GP'])
          _nmeaSentence(
            '${talker}GGA,123520.00,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,',
          ),
      ];

      expect(extractor.add(ascii.encode(sentences.join())), sentences);
    });

    test('extracts mixed GGA data received one byte at a time', () {
      final extractor = GgaSentenceExtractor();
      final sentences = [
        for (final talker in ['GB', 'GN', 'GP'])
          _nmeaSentence(
            '${talker}GGA,123520.00,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,',
          ),
      ];
      final bytes = [
        for (final sentence in sentences) ...[
          0xd3,
          0x00,
          0xff,
          ...ascii.encode('$sentence\r\n'),
          0x80,
        ],
      ];
      final result = <String>[];

      for (final byte in bytes) {
        result.addAll(extractor.add([byte]));
      }

      expect(result, sentences);
    });

    test('recovers from incomplete and binary-corrupted GBGGA data', () {
      final extractor = GgaSentenceExtractor();
      final sentence = _nmeaSentence(
        'GBGGA,123520.00,4807.038,N,01131.000,E,4,18,0.9,545.4,M,46.9,M,,',
      );

      expect(
        extractor.add([...ascii.encode(r'$GBGGA,incomplete'), 0x00, 0xff]),
        isEmpty,
      );
      expect(
        extractor.add([
          ...ascii.encode(r'$GBGGA,corrupted,'),
          0x80,
          ...ascii.encode('*00\r\n'),
          ...ascii.encode(r'$GBGGA,invalid*Q7'),
          ...ascii.encode(sentence),
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
