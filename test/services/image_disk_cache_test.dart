import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:chuk_chat/services/image_disk_cache.dart';

Uint8List _jpeg(int width, int height) {
  final image = img.Image(width: width, height: height);
  // A gradient, so the JPEG is not trivially small.
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      image.setPixelRgb(x, y, x % 256, y % 256, (x + y) % 256);
    }
  }
  return img.encodeJpg(image, quality: 90);
}

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('image_disk_cache_test');
    ImageDiskCache.debugRootOverride = dir;
  });

  tearDown(() {
    ImageDiskCache.debugRootOverride = null;
    ImageDiskCache.debugReset();
    dir.deleteSync(recursive: true);
  });

  test('write then read returns the same bytes', () async {
    final bytes = Uint8List.fromList(List<int>.generate(1000, (i) => i % 256));
    expect(await ImageDiskCache.read('u/a.enc'), isNull);
    await ImageDiskCache.write('u/a.enc', bytes);
    expect(await ImageDiskCache.read('u/a.enc'), bytes);
    // The thumbnail is a separate entry.
    expect(await ImageDiskCache.readThumb('u/a.enc'), isNull);
  });

  test('file names do not contain the storage path', () async {
    await ImageDiskCache.write('user-123/secret.enc', Uint8List(10));
    final names = dir.listSync().map((e) => e.path).join(' ');
    expect(names, isNot(contains('secret')));
    expect(names, isNot(contains('user-123')));
  });

  test('a path marked as PDF stays marked until removed', () async {
    expect(await ImageDiskCache.isPdf('u/doc.enc'), isFalse);
    await ImageDiskCache.markPdf('u/doc.enc');
    expect(await ImageDiskCache.isPdf('u/doc.enc'), isTrue);
    await ImageDiskCache.remove('u/doc.enc');
    expect(await ImageDiskCache.isPdf('u/doc.enc'), isFalse);
  });

  test('remove deletes picture and thumbnail', () async {
    await ImageDiskCache.write('u/b.enc', Uint8List(10));
    await ImageDiskCache.writeThumb('u/b.enc', Uint8List(5));
    await ImageDiskCache.remove('u/b.enc');
    expect(await ImageDiskCache.read('u/b.enc'), isNull);
    expect(await ImageDiskCache.readThumb('u/b.enc'), isNull);
  });

  test('makeThumbnail shrinks the longest side to thumbMaxSide', () async {
    final full = _jpeg(2048, 1024);
    final thumb = await ImageDiskCache.makeThumbnail(full);
    expect(thumb, isNotNull);
    final decoded = img.decodeImage(thumb!)!;
    expect(decoded.width, ImageDiskCache.thumbMaxSide);
    expect(decoded.height, ImageDiskCache.thumbMaxSide ~/ 2);
    expect(thumb.length, lessThan(full.length ~/ 4));
  });

  test('makeThumbnail keeps portrait pictures upright', () async {
    final thumb = await ImageDiskCache.makeThumbnail(_jpeg(600, 1200));
    final decoded = img.decodeImage(thumb!)!;
    expect(decoded.height, ImageDiskCache.thumbMaxSide);
    expect(decoded.width, ImageDiskCache.thumbMaxSide ~/ 2);
  });

  test('a small picture comes back unchanged', () async {
    final small = _jpeg(200, 100);
    expect(await ImageDiskCache.makeThumbnail(small), small);
  });

  test('a picture with transparency stays PNG', () async {
    final image = img.Image(width: 1200, height: 800, numChannels: 4);
    img.fill(image, color: img.ColorRgba8(255, 0, 0, 0));
    final thumb = await ImageDiskCache.makeThumbnail(img.encodePng(image));
    expect(thumb, isNotNull);
    expect(img.findFormatForData(thumb!), img.ImageFormat.png);
  });

  test('bytes that are not a picture give null', () async {
    final pdf = Uint8List.fromList('%PDF-1.7 not a picture'.codeUnits);
    expect(await ImageDiskCache.makeThumbnail(pdf), isNull);
  });

  test('prune removes the oldest files first', () async {
    final old = File('${dir.path}/old.img')..writeAsBytesSync(Uint8List(600));
    old.setLastModifiedSync(DateTime(2020));
    final fresh = File('${dir.path}/new.img')..writeAsBytesSync(Uint8List(600));
    await ImageDiskCache.pruneForTest(dir, 1000);
    expect(old.existsSync(), isFalse);
    expect(fresh.existsSync(), isTrue);
  });

  // The point of the cache: a reopened media manager reads 100 small
  // thumbnails from disk instead of downloading, decrypting and decoding 100
  // full pictures. This guards the read path against getting slow again.
  test('reading 100 cached thumbnails is fast', () async {
    final thumb = (await ImageDiskCache.makeThumbnail(_jpeg(2048, 1536)))!;
    for (int i = 0; i < 100; i++) {
      await ImageDiskCache.writeThumb('u/$i.enc', thumb);
    }
    final watch = Stopwatch()..start();
    for (int i = 0; i < 100; i++) {
      expect(await ImageDiskCache.readThumb('u/$i.enc'), isNotNull);
    }
    watch.stop();
    expect(watch.elapsedMilliseconds, lessThan(1000));
  });
}
