#include <iostream>
#include <fstream>
#include <cmath>
#include <iomanip>
#include <string>

using namespace std;

#define MAX_SIZE 10

// Round to 1 decimal place and handle -0.0
static inline double formatOutput(double v) {
    double rounded = round(v * 10.0) / 10.0;
    // Convert -0.0 to 0.0
    if (rounded == 0.0 || rounded == -0.0) {
        return 0.0;
    }
    return rounded;
}

// Compute autocorrelation of signal
void computeAutocorrelation(double signal[MAX_SIZE], double autocorr[MAX_SIZE], int N) {
    for (int k = 0; k < N; k++) {
        autocorr[k] = 0.0;
        for (int n = k; n < N; n++) {
            autocorr[k] += signal[n] * signal[n - k];
        }
        autocorr[k] /= N;
    }
}

// Compute crosscorrelation between desired signal and input signal
void computeCrosscorrelation(double desired_signal[MAX_SIZE], double input_signal[MAX_SIZE], double crosscorr[MAX_SIZE], int N) {
    for (int k = 0; k < N; k++) {
        crosscorr[k] = 0.0;
        for (int n = k; n < N; n++) {
            crosscorr[k] += desired_signal[n] * input_signal[n - k];
        }
        crosscorr[k] /= N;
    }
}

// Create Toeplitz matrix from autocorrelation
void createToeplitzMatrix(double autocorr[MAX_SIZE], double R[MAX_SIZE][MAX_SIZE], int N) {
    for (int i = 0; i < N; i++) {
        for (int j = 0; j < N; j++) {
            R[i][j] = autocorr[abs(i - j)];
        }
    }
}

// Solve linear system using Gaussian elimination with partial pivoting
void solveLinearSystem(double A[MAX_SIZE][MAX_SIZE], double b[MAX_SIZE], double x[MAX_SIZE], int N) {
    double augmented[MAX_SIZE][MAX_SIZE + 1];
    
    // Create augmented matrix [A|b]
    for (int i = 0; i < N; i++) {
        for (int j = 0; j < N; j++) {
            augmented[i][j] = A[i][j];
        }
        augmented[i][N] = b[i];
    }
    
    // Forward elimination with partial pivoting
    for (int i = 0; i < N; i++) {
        // Find pivot
        int maxRow = i;
        for (int k = i + 1; k < N; k++) {
            if (abs(augmented[k][i]) > abs(augmented[maxRow][i])) {
                maxRow = k;
            }
        }
        
        // Swap rows
        for (int k = i; k <= N; k++) {
            double tmp = augmented[maxRow][k];
            augmented[maxRow][k] = augmented[i][k];
            augmented[i][k] = tmp;
        }
        
        // Eliminate column entries below pivot
        for (int k = i + 1; k < N; k++) {
            double factor = augmented[k][i] / augmented[i][i];
            for (int j = i; j <= N; j++) {
                augmented[k][j] -= factor * augmented[i][j];
            }
        }
    }
    
    // Back substitution
    for (int i = N - 1; i >= 0; i--) {
        x[i] = augmented[i][N];
        for (int j = i + 1; j < N; j++) {
            x[i] -= augmented[i][j] * x[j];
        }
        x[i] /= augmented[i][i];
    }
}

// Compute Wiener coefficients
void computeWienerCoefficients(double desired_signal[MAX_SIZE], double input_signal[MAX_SIZE], int N, double optimize_coefficients[MAX_SIZE]) {
    double autocorr[MAX_SIZE];
    double crosscorr[MAX_SIZE];
    double R[MAX_SIZE][MAX_SIZE];

    computeAutocorrelation(input_signal, autocorr, N);
    computeCrosscorrelation(desired_signal, input_signal, crosscorr, N);
    createToeplitzMatrix(autocorr, R, N);
    solveLinearSystem(R, crosscorr, optimize_coefficients, N);
}

// Apply Wiener filter
void applyWienerFilter(double input_signal[MAX_SIZE], double optimize_coefficients[MAX_SIZE], double output_signal[MAX_SIZE], int N) {
    for (int n = 0; n < N; n++) {
        output_signal[n] = 0.0;
        for (int k = 0; k <= n; k++) {
            output_signal[n] += optimize_coefficients[k] * input_signal[n - k];
        }
    }
}

// Compute MMSE 
double computeMMSE(double desired_signal[MAX_SIZE], double output_signal[MAX_SIZE], int N) {
    double mmse = 0.0;
    for (int n = 0; n < N; n++) {
        double error = desired_signal[n] - output_signal[n];
        mmse += error * error;
    }
    mmse /= N;
    return mmse;
}

// Read signal from file
int readSignalFromFile(const string &filename, double signal[MAX_SIZE]) {
    ifstream file(filename);
    if (!file.is_open()) throw runtime_error("Cannot open file: " + filename);

    int count = 0;
    while (file >> signal[count] && count < MAX_SIZE) {
        count++;
    }
    file.close();
    return count;
}

// Write output to file 
void writeOutputToFile(const string &filename, double output_signal[], int N, double mmse) {
    ofstream file(filename);
    if (!file.is_open()) throw runtime_error("Cannot open output file");

    file << fixed << setprecision(1);
    file << "Filtered output:";
    for (int i = 0; i < N; ++i) {
        file << " " << formatOutput(output_signal[i]);
    }
    file << "\n";

    file << "MMSE: " << formatOutput(mmse) << "\n";
    file.close();
}

// Print to terminal - format output here
void printToTerminal(const double output_signal[MAX_SIZE], int N, double mmse) {
    cout << fixed << setprecision(1);
    cout << "Filtered output:";
    for (int i = 0; i < N; ++i) {
        cout << " " << formatOutput(output_signal[i]);
    }
    cout << "\n";
    cout << "MMSE: " << formatOutput(mmse) << "\n";
}

int main() {
    try {
        double desired_signal[MAX_SIZE], input_signal[MAX_SIZE];
        double output_signal[MAX_SIZE], optimize_coefficients[MAX_SIZE];

        int SIZE = readSignalFromFile("desired.txt", desired_signal);
        int N2 = readSignalFromFile("input.txt", input_signal);

        if (SIZE != N2) {
            ofstream errorFile("output.txt");
            errorFile << "Error: size not match" << endl;
            errorFile.close();
            cerr << "Error: size not match" << endl;
            return 1;  
        }

        computeWienerCoefficients(desired_signal, input_signal, SIZE, optimize_coefficients);
        applyWienerFilter(input_signal, optimize_coefficients, output_signal, SIZE);
        double mmse = computeMMSE(desired_signal, output_signal, SIZE);

        writeOutputToFile("output.txt", output_signal, SIZE, mmse);
        printToTerminal(output_signal, SIZE, mmse);
        // cout << "Done! Check output.txt for results." << endl;

    } catch (const exception &e) {
        cerr << "Error: " << e.what() << endl;
        ofstream errorFile("output.txt");
        errorFile << "Error: " << e.what() << endl;
        errorFile.close();
        return 1;
    }

    return 0;
}
