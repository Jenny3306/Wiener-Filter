# Wiener Filter

An Assembly-based implementation of the Wiener Filter algorithm for image processing, developed as part of a Computer Architecture assignment at HCMUT.

## 📋 Overview

This project implements the Wiener Filter, a fundamental signal processing technique used for image denoising and restoration. The implementation combines **Assembly code** (81.3%) for performance-critical operations with **Python** (9.7%) and **C++** (9%) for support utilities and testing.

## 🎯 Purpose

This repository demonstrates:
- Low-level programming concepts in Assembly language
- Algorithm optimization at the assembly level
- Image processing techniques
- Integration between multiple programming languages

## 📁 Project Structure

- **Assembly Code**: Core Wiener Filter implementation optimized for performance
- **Python Scripts**: Testing, visualization, and result analysis
- **C++ Utilities**: Helper functions and additional processing tools

## 🛠️ Requirements

Before running this project, ensure you have the following installed:

- **Assembler**: NASM (Netwide Assembler) or compatible
- **Linker**: GNU LD or compatible
- **Python**: 3.7 or higher (for testing and visualization)
- **C++ Compiler**: GCC or Clang (for C++ components)
- **Build Tools**: Make (optional but recommended)

## 🚀 Getting Started

### Installation

1. Clone the repository:
   ```bash
   git clone https://github.com/Jenny3306/Wiener-Filter.git
   cd Wiener-Filter
   ```

2. Install Python dependencies:
   ```bash
   pip install -r requirements.txt
   ```

3. Compile Assembly and C++ code:
   ```bash
   make
   ```

### Usage

Run the Wiener Filter:
```bash
./wiener_filter <input_image> <output_image>
```

For testing:
```bash
python test.py
```

## 📊 Language Composition

- **Assembly**: 81.3% - Core algorithm implementation
- **Python**: 9.7% - Testing and visualization
- **C++**: 9% - Utility functions

## 📚 References

- HCMUT Computer Architecture Course
- Wiener Filtering Theory and Applications
- Assembly Language Programming Guides

## 📝 License

This project is created for educational purposes as part of a HCMUT assignment.

## ✨ Features

- Optimized Assembly implementation for performance
- Image denoising and restoration
- Support for various image formats
- Comprehensive testing suite

---

For questions or suggestions, feel free to open an issue or contact the repository owner.