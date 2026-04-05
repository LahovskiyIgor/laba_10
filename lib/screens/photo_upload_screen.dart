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
  img.Image? _processedImage;
  String _currentFilter = 'original';
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
            _processedImage = null;
            _currentFilter = 'original';
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
        _processedImage = result;
        _currentFilter = 'fft';
        _isProcessing = false;
      });
    } catch (e) {
      setState(() => _isProcessing = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка при применении БПФ: $e')),
        );
      }
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

  /// Фильтр Лапласа в пространственной области (свертка с ядром)
  Future<void> _applyLaplacianSpatial() async {
    if (_originalImage == null || _isProcessing) return;

    setState(() => _isProcessing = true);

    try {
      final result = await compute(_computeLaplacianSpatial, {
        'image': _originalImage!.getBytes(),
        'width': _originalImage!.width,
        'height': _originalImage!.height,
      });

      setState(() {
        _processedImage = result;
        _currentFilter = 'laplacian_spatial';
        _isProcessing = false;
      });
    } catch (e) {
      setState(() => _isProcessing = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка при применении фильтра Лапласа: $e')),
        );
      }
    }
  }

  /// Вычисление фильтра Лапласа в пространственной области в изоляте
  static img.Image _computeLaplacianSpatial(Map<String, dynamic> data) {
    final List<int> bytes = data['image'] as List<int>;
    final int width = data['width'] as int;
    final int height = data['height'] as int;

    final image = img.Image(width: width, height: height);
    image.setBytes(bytes);

    // Преобразуем в градации серого для упрощения
    final grayImage = img.grayscale(image);

    // Ядро Лапласа 3x3 (вариант с диагоналями)
    // [ 1  1  1 ]
    // [ 1 -8  1 ]
    // [ 1  1  1 ]
    final kernel = [
      [1, 1, 1],
      [1, -8, 1],
      [1, 1, 1],
    ];

    final resultImage = img.Image(width: width, height: height);

    for (int y = 1; y < height - 1; y++) {
      for (int x = 1; x < width - 1; x++) {
        double sum = 0;

        // Применяем свертку
        for (int ky = -1; ky <= 1; ky++) {
          for (int kx = -1; kx <= 1; kx++) {
            final pixel = grayImage.getPixel(x + kx, y + ky);
            sum += pixel.r * kernel[ky + 1][kx + 1];
          }
        }

        // Инвертируем и добавляем к исходному значению для усиления границ
        int newValue = grayImage.getPixel(x, y).r - sum.toInt();
        newValue = newValue.clamp(0, 255);

        resultImage.setPixelRgba(x, y, newValue, newValue, newValue, 255);
      }
    }

    return resultImage;
  }

  /// Фильтр на основе оператора Лапласа (частотная область через БПФ)
  Future<void> _applyLaplacianFrequency() async {
    if (_originalImage == null || _isProcessing) return;

    setState(() => _isProcessing = true);

    try {
      // Определяем размер (степень двойки для БПФ)
      int targetWidth = _toPowerOfTwo(math.min(_originalImage!.width, 512));
      int targetHeight = _toPowerOfTwo(math.min(_originalImage!.height, 512));

      // Ресайз и градации серого
      final resizedImg = img.copyResize(
        _originalImage!,
        width: targetWidth,
        height: targetHeight,
        interpolation: img.Interpolation.average,
      );
      final grayImage = img.grayscale(resizedImg);

      // Подготовка данных для БПФ
      final realData = Float64List(targetWidth * targetHeight);
      final imagData = Float64List(targetWidth * targetHeight);

      int index = 0;
      for (var pixel in grayImage) {
        realData[index] = pixel.r.toDouble();
        index++;
      }

      final result = await compute(_computeLaplacianFrequency, {
        'real': realData,
        'imag': imagData,
        'width': targetWidth,
        'height': targetHeight,
      });

      setState(() {
        _processedImage = result;
        _currentFilter = 'laplacian_freq';
        _isProcessing = false;
      });
    } catch (e) {
      setState(() => _isProcessing = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка при применении фильтра Лапласа (частотная область): $e')),
        );
      }
    }
  }

  /// Вычисление фильтра Лапласа в частотной области в изоляте
  static img.Image _computeLaplacianFrequency(Map<String, dynamic> data) {
    final Float64List realData = data['real'] as Float64List;
    final Float64List imagData = data['imag'] as Float64List;
    final int width = data['width'] as int;
    final int height = data['height'] as int;

    // Преобразуем в 2D массивы
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
      _fft1D(real[y], imag[y]);
    }

    // Применяем БПФ по столбцам
    for (int x = 0; x < width; x++) {
      Float64List colReal = Float64List(height);
      Float64List colImag = Float64List(height);
      for (int y = 0; y < height; y++) {
        colReal[y] = real[y][x];
        colImag[y] = imag[y][x];
      }

      _fft1D(colReal, colImag);

      for (int y = 0; y < height; y++) {
        real[y][x] = colReal[y];
        imag[y][x] = colImag[y];
      }
    }

    // Применяем фильтр Лапласа в частотной области
    // H(u,v) = -4π²(u² + v²) для непрерывного случая
    // Для дискретного: H(u,v) = 2(cos(2πu/W) + cos(2πv/H) - 2)
    final centerShiftedReal = List.generate(height, (_) => List.filled(width, 0.0));
    final centerShiftedImag = List.generate(height, (_) => List.filled(width, 0.0));

    int cx = width ~/ 2;
    int cy = height ~/ 2;

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        // Сдвиг спектра
        int shiftedY = (y + cy) % height;
        int shiftedX = (x + cx) % width;
        centerShiftedReal[y][x] = real[shiftedY][shiftedX];
        centerShiftedImag[y][x] = imag[shiftedY][shiftedX];
      }
    }

    // Применяем фильтр Лапласа
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        // Нормализованные координаты
        double u = (x < cx) ? x / width : (x - width) / width;
        double v = (y < cy) ? y / height : (y - height) / height;

        // Передаточная функция Лапласа
        double H = -4 * math.pi * math.pi * (u * u + v * v);

        centerShiftedReal[y][x] *= H;
        centerShiftedImag[y][x] *= H;
      }
    }

    // Обратный сдвиг
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        int origY = (y + cy) % height;
        int origX = (x + cx) % width;
        real[origY][origX] = centerShiftedReal[y][x];
        imag[origY][origX] = centerShiftedImag[y][x];
      }
    }

    // Обратное БПФ по столбцам
    for (int x = 0; x < width; x++) {
      Float64List colReal = Float64List(height);
      Float64List colImag = Float64List(height);
      for (int y = 0; y < height; y++) {
        colReal[y] = real[y][x];
        colImag[y] = imag[y][x];
      }

      _ifft1D(colReal, colImag);

      for (int y = 0; y < height; y++) {
        real[y][x] = colReal[y];
        imag[y][x] = colImag[y];
      }
    }

    // Обратное БПФ по строкам
    for (int y = 0; y < height; y++) {
      _ifft1D(real[y], imag[y]);
    }

    // Нормализация результата
    double minVal = double.infinity;
    double maxVal = double.negativeInfinity;

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        double val = real[y][x];
        if (val < minVal) minVal = val;
        if (val > maxVal) maxVal = val;
      }
    }

    final resultImage = img.Image(width: width, height: height);
    double range = maxVal - minVal;

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        int value = range > 0
            ? ((real[y][x] - minVal) / range * 255).toInt().clamp(0, 255)
            : 128;
        resultImage.setPixelRgba(x, y, value, value, value, 255);
      }
    }

    return resultImage;
  }

  /// Обратное БПФ (алгоритм Кули-Тьюки)
  static void _ifft1D(Float64List real, Float64List imag) {
    final int n = real.length;

    // Инвертируем мнимую часть для прямого БПФ
    for (int i = 0; i < n; i++) {
      imag[i] = -imag[i];
    }

    // Применяем прямое БПФ
    _fft1D(real, imag);

    // Инвертируем обратно и нормализуем
    for (int i = 0; i < n; i++) {
      real[i] = real[i] / n;
      imag[i] = -imag[i] / n;
    }
  }

  void _resetToOriginal() {
    setState(() {
      _processedImage = null;
      _currentFilter = 'original';
    });
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
                        : _processedImage != null
                            ? Image.memory(
                                Uint8List.fromList(img.encodePng(_processedImage!)),
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
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: _isProcessing ? null : _applyFFT,
                    icon: const Icon(Icons.waves),
                    label: const Text('БПФ'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: _isProcessing ? null : _applyLaplacianSpatial,
                    icon: const Icon(Icons.blur_on),
                    label: const Text('Лаплас (простр.)'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: _isProcessing ? null : _applyLaplacianFrequency,
                    icon: const Icon(Icons.filter_vintage),
                    label: const Text('Лаплас (частотн.)'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: _isProcessing ? null : _resetToOriginal,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Оригинал'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
