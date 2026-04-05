import 'dart:io';
import 'dart:math' as math;
import 'dart:async';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;

class PhotoUploadScreen extends StatefulWidget {
  const PhotoUploadScreen({super.key});

  @override
  State<PhotoUploadScreen> createState() => _PhotoUploadScreenState();
}

class _PhotoUploadScreenState extends State<PhotoUploadScreen> {
  File? _selectedImage;
  img.Image? _originalImage;
  img.Image? _fftImage;
  final ImagePicker _picker = ImagePicker();
  bool _isProcessing = false;

  Future<void> _pickImage() async {
    try {
      final XFile? pickedFile = await _picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 100,
      );

      if (pickedFile != null) {
        final bytes = await pickedFile.readAsBytes();
        final decodedImage = img.decodeImage(bytes);

        if (decodedImage != null) {
          setState(() {
            _selectedImage = File(pickedFile.path);
            _originalImage = decodedImage;
            _fftImage = null;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка при выборе изображения: $e')),
        );
      }
    }
  }

  /// Быстрое преобразование Фурье для изображения в градациях серого
  Future<void> _applyFFT() async {
    if (_originalImage == null || _isProcessing) return;

    setState(() => _isProcessing = true);

    try {
      // 1. ОПРЕДЕЛЯЕМ РАЗМЕР (Степень двойки обязательна для Cooley-Tukey)
      // Ограничиваем до 512 или 1024, чтобы не перегружать память мобилки
      int targetWidth = _toPowerOfTwo(math.min(_originalImage!.width, 1024));
      int targetHeight = _toPowerOfTwo(math.min(_originalImage!.height, 1024));

      // 2. РЕСАЙЗ И ГРЕЙСКЕЙЛ
      final resizedImg = img.copyResize(
          _originalImage!,
          width: targetWidth,
          height: targetHeight,
          interpolation: img.Interpolation.average
      );
      final grayImage = img.grayscale(resizedImg);

      // 3. ИСПОЛЬЗУЕМ TYPED DATA (Float64List работает в разы быстрее)
      final realData = Float64List(targetWidth * targetHeight);
      final imagData = Float64List(targetWidth * targetHeight);

      int index = 0;
      for (var pixel in grayImage) {
        // pixel.r — это значение красного канала (в грейскейле r=g=b)
        realData[index] = pixel.r.toDouble();
        index++;
      }

      final result = await compute(_computeFFT, {
        'real': realData,
        'imag': imagData,
        'width': targetWidth,
        'height': targetHeight,
      });

      setState(() {
        _fftImage = result;
        _isProcessing = false;
      });
    } catch (e) {
      setState(() => _isProcessing = false);
      // ... обработка ошибок
    }
  }
  int _toPowerOfTwo(int n) {
    int p = 1;
    while (p * 2 <= n) {
      p *= 2;
    }
    return p;
  }

  /// Функция для вычисления БПФ в изоляте
  static img.Image _computeFFT(Map<String, dynamic> data) {
    // Явное приведение к Float64List
    final Float64List realData = data['real'] as Float64List;
    final Float64List imagData = data['imag'] as Float64List;
    final int width = data['width'] as int;
    final int height = data['height'] as int;

    // Используем Float64List для каждой строки для совместимости с _fft1D
    List<Float64List> real = List.generate(height, (_) => Float64List(width));
    List<Float64List> imag = List.generate(height, (_) => Float64List(width));

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        real[y][x] = realData[y * width + x];
        imag[y][x] = imagData[y * width + x];
      }
    }

    // Применяем БПФ по строкам
    for (int y = 0; y < height; y++) {
      _fft1D(real[y], imag[y]); // Теперь ошибки не будет
    }

    // Применяем БПФ по столбцам
    for (int x = 0; x < width; x++) {
      Float64List colReal = Float64List(height);
      Float64List colImag = Float64List(height);
      for (int y = 0; y < height; y++) {
        colReal[y] = real[y][x];
        colImag[y] = imag[y][x];
      }

      _fft1D(colReal, colImag); // И здесь тоже

      for (int y = 0; y < height; y++) {
        real[y][x] = colReal[y];
        imag[y][x] = colImag[y];
      }
    }

    // Вычисляем магнитуду спектра
    List<List<double>> magnitude = List.generate(height, (_) => List.filled(width, 0.0));
    double maxMag = 0;

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        magnitude[y][x] = math.sqrt(real[y][x] * real[y][x] + imag[y][x] * imag[y][x]);
        if (magnitude[y][x] > maxMag) {
          maxMag = magnitude[y][x];
        }
      }
    }

    // Сдвигаем спектр (центр в середине)
    List<List<double>> shiftedMagnitude = List.generate(height, (_) => List.filled(width, 0.0));
    int cx = width ~/ 2;
    int cy = height ~/ 2;

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        int newX = (x + cx) % width;
        int newY = (y + cy) % height;
        shiftedMagnitude[newY][newX] = magnitude[y][x];
      }
    }

    // Логарифмическое масштабирование для визуализации
    List<List<double>> logMagnitude = List.generate(height, (_) => List.filled(width, 0.0));
    double maxLog = 0;

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        // Формула: c * log(1 + |F|)
        double val = math.log(1 + shiftedMagnitude[y][x]);
        logMagnitude[y][x] = val;
        if (val > maxLog) maxLog = val;
      }
    }

// 3. Нормализуем к диапазону 0-255
    final resultImage = img.Image(width: width, height: height);
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        int value = maxLog > 0
            ? (logMagnitude[y][x] / maxLog * 255).toInt()
            : 0;
        resultImage.setPixelRgba(x, y, value, value, value, 255);
      }
    }

    return resultImage;
  }

  /// Одномерное БПФ (алгоритм Кули-Тьюки)
  static void _fft1D(Float64List real, Float64List imag) {
    final int n = real.length;
    // Теперь n всегда 2^k, поэтому алгоритм отработает корректно

    int j = 0;
    for (int i = 0; i < n; i++) {
      if (i < j) {
        final tempR = real[i];
        final tempI = imag[i];
        real[i] = real[j];
        imag[i] = imag[j];
        real[j] = tempR;
        imag[j] = tempI;
      }
      int m = n >> 1; // Битовый сдвиг вместо ~/ 2
      while (m >= 1 && j >= m) {
        j -= m;
        m >>= 1;
      }
      j += m;
    }

    // Основной цикл бабочки
    for (int len = 2; len <= n; len <<= 1) {
      double ang = 2 * math.pi / len * -1;
      double wlenR = math.cos(ang);
      double wlenI = math.sin(ang);
      for (int i = 0; i < n; i += len) {
        double wR = 1;
        double wI = 0;
        for (int k = 0; k < len / 2; k++) {
          int uIdx = i + k;
          int vIdx = i + k + len ~/ 2;
          double uR = real[uIdx];
          double uI = imag[uIdx];
          double vR = real[vIdx] * wR - imag[vIdx] * wI;
          double vI = real[vIdx] * wI + imag[vIdx] * wR;
          real[uIdx] = uR + vR;
          imag[uIdx] = uI + vI;
          real[vIdx] = uR - vR;
          imag[vIdx] = uI - vI;
          double nextWR = wR * wlenR - wI * wlenI;
          wI = wR * wlenI + wI * wlenR;
          wR = nextWR;
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Загрузка фото'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (_selectedImage != null)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: _isProcessing
                        ? const Center(child: CircularProgressIndicator())
                        : _fftImage != null
                            ? Image.memory(
                                Uint8List.fromList(img.encodePng(_fftImage!)),
                                fit: BoxFit.contain,
                              )
                            : Image.file(
                                _selectedImage!,
                                fit: BoxFit.contain,
                              ),
                  ),
                ),
              )
            else
              const Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.image_outlined, size: 80, color: Colors.grey),
                  SizedBox(height: 16),
                  Text(
                    'Фото не выбрано',
                    style: TextStyle(fontSize: 18, color: Colors.grey),
                  ),
                ],
              ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ElevatedButton.icon(
                  onPressed: _isProcessing ? null : _pickImage,
                  icon: const Icon(Icons.photo_library),
                  label: const Text('Выбрать из галереи'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  ),
                ),
                if (_originalImage != null) ...[
                  const SizedBox(width: 16),
                  ElevatedButton.icon(
                    onPressed: _isProcessing ? null : _applyFFT,
                    icon: const Icon(Icons.waves),
                    label: const Text('Применить БПФ'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                    ),
                  ),
                  const SizedBox(width: 16),
                  ElevatedButton.icon(
                    onPressed: _isProcessing
                        ? null
                        : () {
                            setState(() {
                              _fftImage = null;
                            });
                          },
                    icon: const Icon(Icons.refresh),
                    label: const Text('Оригинал'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
