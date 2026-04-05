import 'dart:io';
import 'dart:math' as math;
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
  void _applyFFT() {
    if (_originalImage == null) return;

    // Конвертируем в градации серого
    final grayImage = img.grayscale(_originalImage!);
    final width = grayImage.width;
    final height = grayImage.height;

    // Создаем комплексные данные (вещественная и мнимая части)
    List<List<double>> real = List.generate(height, (_) => List.filled(width, 0.0));
    List<List<double>> imag = List.generate(height, (_) => List.filled(width, 0.0));

    // Заполняем вещественную часть данными изображения
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        real[y][x] = grayImage.getPixel(x, y).r.toDouble();
      }
    }

    // Применяем БПФ по строкам
    for (int y = 0; y < height; y++) {
      _fft1D(real[y], imag[y]);
    }

    // Применяем БПФ по столбцам
    for (int x = 0; x < width; x++) {
      List<double> colReal = List.generate(height, (y) => real[y][x]);
      List<double> colImag = List.generate(height, (y) => imag[y][x]);
      _fft1D(colReal, colImag);
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
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        logMagnitude[y][x] = math.log(1 + shiftedMagnitude[y][x] / maxMag * 255);
      }
    }

    // Нормализуем и создаем изображение результата
    double maxLog = 0;
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        if (logMagnitude[y][x] > maxLog) {
          maxLog = logMagnitude[y][x];
        }
      }
    }

    final resultImage = img.Image(width: width, height: height);
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        int value = (logMagnitude[y][x] / maxLog * 255).toInt();
        value = value.clamp(0, 255);
        resultImage.setPixelRgba(x, y, value, value, value, 255);
      }
    }

    setState(() {
      _fftImage = resultImage;
    });
  }

  /// Одномерное БПФ (алгоритм Кули-Тьюки)
  void _fft1D(List<double> real, List<double> imag) {
    int n = real.length;
    if (n <= 1) return;

    // Битовая реверсия
    int j = 0;
    for (int i = 0; i < n - 1; i++) {
      if (i < j) {
        double tempR = real[i];
        double tempI = imag[i];
        real[i] = real[j];
        imag[i] = imag[j];
        real[j] = tempR;
        imag[j] = tempI;
      }
      int k = n ~/ 2;
      while (k <= j) {
        j -= k;
        k ~/= 2;
      }
      j += k;
    }

    // Бабочка
    int m = 2;
    while (m <= n) {
      double angle = -2 * math.pi / m;
      double wr = math.cos(angle);
      double wi = math.sin(angle);
      
      for (int i = 0; i < n; i += m) {
        double wkr = 1.0;
        double wki = 0.0;
        
        for (int k = 0; k < m ~/ 2; k++) {
          int evenIdx = i + k;
          int oddIdx = i + k + m ~/ 2;
          
          double tr = wkr * real[oddIdx] - wki * imag[oddIdx];
          double ti = wkr * imag[oddIdx] + wki * real[oddIdx];
          
          real[oddIdx] = real[evenIdx] - tr;
          imag[oddIdx] = imag[evenIdx] - ti;
          real[evenIdx] += tr;
          imag[evenIdx] += ti;
          
          double tempWkr = wkr * wr - wki * wi;
          wki = wkr * wi + wki * wr;
          wkr = tempWkr;
        }
      }
      m *= 2;
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
                    child: _fftImage != null
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
                  onPressed: _pickImage,
                  icon: const Icon(Icons.photo_library),
                  label: const Text('Выбрать из галереи'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  ),
                ),
                if (_originalImage != null) ...[
                  const SizedBox(width: 16),
                  ElevatedButton.icon(
                    onPressed: _applyFFT,
                    icon: const Icon(Icons.waves),
                    label: const Text('Применить БПФ'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                    ),
                  ),
                  const SizedBox(width: 16),
                  ElevatedButton.icon(
                    onPressed: () {
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
