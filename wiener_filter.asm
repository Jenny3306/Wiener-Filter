.data
# Khai báo các chuỗi tên file để đọc và ghi
# Khai báo vs .asciiz tạo chuỗi kết thúc bằng '\0'
input_file:   .asciiz "input.txt"
desired_file: .asciiz "desired.txt"
output_file:  .asciiz "output.txt"

buf_size:     .word 32768       # lưu kích thước (32KB)
buffer:       .space 32768      # vùng nhớ 32KB để đọc nội dung file

NUM_SAMPLES:  .word 10          # Mỗi mảng có 10 ptu
desired_signal:      .space 40  # 10 floats x 4 bytes : tín hiệu mong muốn
input_signal:        .space 40  # tín hiệu đầu vào (có nhiễu)
crosscorr:    .space 40         # tương quan chéo
autocorr:     .space 40         # tự tương quan

R:            .space 400        # Ma trận Toeplitz 10x10
aug:          .space 440        # Ma trận phụ 10 x (10+1) floats = 440 bytes
optimize_coefficient: .space 40
output_signal:        .space 40

# Các hằng số thường dùng
mmse:         .float 0.0
zero_f:       .float 0.0
point1_f:     .float 0.1
one_f:        .float 1.0
ten:          .float 10.0
hundred:      .float 100.0
half:         .float 0.5

header_filtered: .asciiz "Filtered output: "
header_mmse:  .asciiz "\nMMSE: "
count_input:   .word 0          
count_desired: .word 0
error_size_str: .asciiz "Error: size not match"

space_str:    .asciiz " "
str_buf:      .space 32
temp_str:     .space 32

.text
.globl main

main:
    # --- STEP 1: Open and read input file for input[] ---
    # Step 1.1: load buffer size into $t0 (to temporarily store the file contents)
    # because we cannot parse it directly from disk 
    # => read it into memory first, then parse from that memory buffer
    la   $t0, buf_size
    lw   $t1, 0($t0)        # t1 = buf_size (32768)

    # Step 1.2: open input_file for reading
    li   $v0, 13            # sys_open
    la   $a0, input_file    # "input.txt"
    li   $a1, 0             # flags = read-only (file access mode - how you want to open the file)
    li   $a2, 0             # file permissions
    syscall
    move $s0, $v0           # save file descriptor into $s0 = fd_input

    # Step 1.3: read file descriptor into memory buffer
    li   $v0, 14            # sys_read
    move $a0, $s0           # fd
    la   $a1, buffer        # buffer address
    move $a2, $t1           # buf_size
    syscall
    move $s1, $v0           # s1 = bytes_read

    # Step 1.4: close the file
    li   $v0, 16            # sys_close
    move $a0, $s0           # fd
    syscall

    # Step 1.5: null-terminate the buffer (make it a C-style string)
    la   $t2, buffer        # start of buffer
    addu $t2, $t2, $s1      # buffer + bytes_read
    sb   $zero, 0($t2)      # put '\0' at end

    # --- STEP 2: Parse 10 floats for input_signal[] ---
    
    la   $t0, buffer        # $t0 = char* p: pointer to current character
    la   $t1, input_signal  # $t1 = destination pointer: con trỏ đến vị trí lưu trong mảng
    # counter: số các chữ số còn lại cần đọc
    li   $t2, 10            # $t2 = numbers left to read (N = 10) - bắt đầu từ 10

parse_input_next_number:
    # Nếu $t2 = 0: đã đọc đủ 10 số => thoát
    beq  $t2, $zero, parse_input_done  

    # skip whitespace
pi_skip_ws:
    lb   $t3, 0($t0)                   # $t3 = *p: load current character
    beq  $t3, $zero, parse_input_done  # end of string (if null terminator, done)
    li   $t4, ' '
    beq  $t3, $t4, pi_advance_ws       # if space => skip

    # similar check for '\n', '\r', '\t' => skip
    li   $t4, '\n'
    beq  $t3, $t4, pi_advance_ws
    li   $t4, '\r'
    beq  $t3, $t4, pi_advance_ws
    li   $t4, '\t'
    beq  $t3, $t4, pi_advance_ws

    # not whitespace → start of token
    j    pi_parse_token

pi_advance_ws:
    addiu $t0, $t0, 1
    j     pi_skip_ws

pi_parse_token:
    # sign, integer part, fractional digit
    li   $t4, 1             # sign = +1 (mặc định là số dương)
    li   $t6, 0             # int_part = 0 (lưu phần nguyên)
    li   $t7, 0             # frac_digit = 0 (lưu phần thập phân)

    # check for '-' (minus sign)
    li   $t5, 45                    # ASCII of '-'
    beq  $t3, $t5, pi_have_minus    # If current character is the minus sign => jump to pi_have_minus
    j    pi_int_start               # if not (positive), read the integer part

pi_have_minus:
    li   $t4, -1            # if this is the minus sign => set sign = -1
    addiu $t0, $t0, 1       # move to the next character (past '-')
    lb   $t3, 0($t0)        # read first digit or '.'

pi_int_start:
    # read all integer digits
pi_int_loop:
    # Kiểm tra có phải chữ số không
    li   $t5, 48                    # ASCII '0'
    blt  $t3, $t5, pi_check_dot     # if < 48 -> không phải chữ số -> stop
    li   $t5, 57                    # ASCII '9'
    bgt  $t3, $t5, pi_check_dot     # if > 57 -> stop

    # digit in [0..9]
    addiu $t3, $t3, -48             # convert ASCII -> digit

    # int_part = int_part * 10 + digit (tích lũy phần nguyên)
    mul   $t6, $t6, 10      
    add   $t6, $t6, $t3

    addiu $t0, $t0, 1       # advance p => move to the next character
    lb    $t3, 0($t0)       # next char
    j     pi_int_loop

pi_check_dot:
    # check optional '.' decimal point
    li   $t5, 46                    # '.'
    bne  $t3, $t5, pi_build_value   # nếu không phải dấu '.' => bỏ qua thập phân

    # we have '.', move to fractional digit
    addiu $t0, $t0, 1       # di chuyển qua dấu chấm
    lb    $t3, 0($t0)       # đọc kí tự tiếp theo sau dấu chấm

    # if next is a digit, take EXACTLY one fractional digit
    li   $t5, 48
    blt  $t3, $t5, pi_build_value
    li   $t5, 57
    bgt  $t3, $t5, pi_build_value

    addiu $t3, $t3, -48     # convert ASCII -> digit (trừ '0')
    move  $t7, $t3          # frac_digit = digit
    addiu $t0, $t0, 1       # move p after frac digit

pi_build_value:
    # tmpInt = int_part * 10 + frac_digit
    mul  $t8, $t6, 10       # ghép phần nguyên và phần thập phân thành 1 số 
    add  $t8, $t8, $t7      # xy

    # convert xy to float and scale by 0.1 -> x.y
    mtc1 $t8, $f0           # từ CPU reg -> FPU reg
    cvt.s.w $f0, $f0        # convert từ int -> single-precision float
    la   $t9, point1_f      # load địa chỉ của hằng số 0.1
    lwc1 $f2, 0($t9)        # $f0 = $f0 x 0.1
    mul.s $f0, $f0, $f2     # $f0 = x.y

    # apply sign
    bltz $t4, pi_negate     # nếu < 0 => nhảy đến pi_negate (thêm dấu âm)
    j    pi_store           # nếu >= 0 => nhảy đến pi_store

pi_negate:
    neg.s $f0, $f0

pi_store:
    swc1 $f0, 0($t1)                # store into input_signal[]
    addiu $t1, $t1, 4               # move destination pointer (tăng con trỏ lên 4 byte để đến vị trí tiếp theo trong mảng input_signal[])
    addiu $t2, $t2, -1              # one less number to read (giảm counter)

    j    parse_input_next_number    # tiếp tục đọc số tiếp theo

parse_input_done:
    # count_input = 10 - t2
    li   $t9, 10
    subu $t9, $t9, $t2              # t9 = numbers parsed from input.txt
    la   $t8, count_input           # load địa chỉ đến biến count_input
    sw   $t9, 0($t8)                # lưu số lượng đã parse

    # --- STEP 3: Open and read desired file for desired_signal[] ---
    
    la   $t0, buf_size
    lw   $t1, 0($t0)        # buf_size

    li   $v0, 13            # sys_open
    la   $a0, desired_file  # "desired.txt"
    li   $a1, 0             # read-only
    li   $a2, 0
    syscall
    move $s0, $v0           # lưu file descriptor vào $s0 = fd_desired

    li   $v0, 14            # sys_read: đọc nội dung từ file desired.txt
    move $a0, $s0
    la   $a1, buffer        # lưu dữ liệu đọc vào memory buffer
    move $a2, $t1
    syscall
    move $s1, $v0           # bytes_read: lưu số byte đã đọc

    li   $v0, 16            # sys close file
    move $a0, $s0
    syscall

    # null-terminate to mke it a C-style string
    la   $t2, buffer
    addu $t2, $t2, $s1
    sb   $zero, 0($t2)

    # --- STEP 4: Parse 10 floats for desired_signal[] ---

    la   $t0, buffer                # char* p: pointer to current character
    la   $t1, desired_signal        # destination pointer to array desired_signal[]
    li   $t2, 10                    # parse 10 numbers (counter bắt đầu từ 10)

parse_desired_next_number:
    beq  $t2, $zero, parse_desired_done

pd_skip_ws:
    lb   $t3, 0($t0)
    beq  $t3, $zero, parse_desired_done     # nếu là '\0' => done
    
    # Nếu là các kí tự sau thì bỏ qua
    li   $t4, ' '
    beq  $t3, $t4, pd_advance_ws
    li   $t4, '\n'
    beq  $t3, $t4, pd_advance_ws
    li   $t4, '\r'
    beq  $t3, $t4, pd_advance_ws
    li   $t4, '\t'
    beq  $t3, $t4, pd_advance_ws

    # Nếu ko phải các kí tự trên => bắt đầu xử lý chữ số
    j    pd_parse_token

pd_advance_ws:
    addiu $t0, $t0, 1               # tăng con trỏ chuỗi lên 1
    j     pd_skip_ws                # quay lại vòng lặp kiểm tra

pd_parse_token:
    li   $t4, 1                     # sign = +1
    li   $t6, 0                     # int_part = 0
    li   $t7, 0                     # frac_digit = 0

    li   $t5, 45                    # ASCII '-'
    beq  $t3, $t5, pd_have_minus    # Nếu là dấu trừ '-' => xử lý
    j    pd_int_start               # Còn ko thì xử lý phần nguyên (bđ đọc số)

pd_have_minus:
    li   $t4, -1                    # nếu là dấu trừ => sign = -1
    addiu $t0, $t0, 1               # Bỏ qua '-'
    lb   $t3, 0($t0)                # đọc kí tự tiếp theo (chữ số đầu tiên)

pd_int_start:

pd_int_loop:
    li   $t5, 48                    # ASCII '0'
    blt  $t3, $t5, pd_check_dot     # Nếu < '0' => không phải digit
    li   $t5, 57                    # ASCII '9'
    bgt  $t3, $t5, pd_check_dot     # Nếu > '9' => ko phải digit

    addiu $t3, $t3, -48             # convert ASCII -> digit (trừ '0')
    # số = int_part x 10 + digit
    mul   $t6, $t6, 10              # int_part x 10
    add   $t6, $t6, $t3             # thêm digit mới

    addiu $t0, $t0, 1               # tăng con trỏ 
    lb    $t3, 0($t0)               # đọc kí tự tiếp theo
    j     pd_int_loop               # lặp lại

pd_check_dot:
    li   $t5, 46                    # ASCII '.'
    bne  $t3, $t5, pd_build_value   # Nếu ko phải decimal point '.' => done

    addiu $t0, $t0, 1               # Bỏ qua '.'
    lb    $t3, 0($t0)               # đọc kí tự sau '.' (phần thập phân)

    li   $t5, 48
    blt  $t3, $t5, pd_build_value   # < '0' → không có phần thập phân
    li   $t5, 57
    bgt  $t3, $t5, pd_build_value   # > '9' → không có phần thập phân

    addiu $t3, $t3, -48             # Convert ASCII → digit
    move  $t7, $t3                  # Lưu vào frac_digit
    addiu $t0, $t0, 1               # Tăng con trỏ

pd_build_value:
    # số đang xét: int_part × 10 + frac_digit
    mul  $t8, $t6, 10
    add  $t8, $t8, $t7

    mtc1 $t8, $f0                   # Move to FPU: 127 (int) → $f0
    cvt.s.w $f0, $f0                # Convert: (int) → (float)
    la   $t9, point1_f              # Load địa chỉ hằng số 0.1
    lwc1 $f2, 0($t9)                # $f2 = 0.1
    mul.s $f0, $f0, $f2             # $f0 = 127.0 × 0.1 = 12.7

    bltz $t4, pd_negate             # Nếu $t4 < 0 (số âm)
    j    pd_store                   # Số dương → lưu luôn

pd_negate:
    neg.s $f0, $f0                  # $f0 = -$f0

pd_store:
    # lưu vào mảng desired_signal[]
    swc1 $f0, 0($t1)                # Lưu float vào mảng desired_signal[]
    addiu $t1, $t1, 4               # Con trỏ += 4 bytes (kích thước float)
    addiu $t2, $t2, -1              # Giảm counter

    j    parse_desired_next_number  # Parse số tiếp theo

parse_desired_done:
    # count_desired = 10 - t2
    li   $t9, 10
    subu $t9, $t9, $t2                  # t9 = numbers parsed from desired.txt
    la   $t8, count_desired             # load địa chỉ của count_desired
    sw   $t9, 0($t8)                    # lưu kết quả

    # --- STEP 5: check size match ---
    la   $t8, count_input
    lw   $t0, 0($t8)                    # $t0 = count_input
    la   $t8, count_desired
    lw   $t1, 0($t8)                    # $t1 = count_desired

    bne  $t0, $t1, size_mismatch        # size different -> error
    beq  $t0, $zero, size_mismatch      # 0 samples -> error

    # --- STEP 6: compute crosscorrelation (tương quan chéo) ---
    # load pointers and N   
    la   $a0, desired_signal            # load address arg0: desired_signal[]
    la   $a1, input_signal              # load address arg1: input_signal[]
    la   $a2, crosscorr                 # load address của crosscorr => mảng đầu ra để lưu tương quan chéo
    lw   $a3, NUM_SAMPLES               # arg2: N (int) = 10
    
    # phải lưu bản sao của các biến trên để giá trị không bị thay đổi sau khi thực hiện các hàm 
    # nếu muốn dùng lại các giá trị cũ
    move $s0, $a0                       # lưu bản sao của desired_signal
    move $s1, $a1                       # lưu bản sao của input_signal
    move $s2, $a3                       # lưu bản sao của N
    
    # --- crosscorrelation(desired_signal[], input_signal[], N) -> crosscorr[] ---
    jal  computeCrosscorrelation

    # --- STEP 7: compute autocorrelation (tự tương quan)---
    ## TODO computeAutocorrelation
    # --- autcorr (input_signal) --> autocorr[]
    move $a0, $s1                       # input_signal[]  (from computeCrosscorrelation)
    la   $a1, autocorr                  # output_signal[]
    move $a2, $s2                       # N
    jal  computeAutocorrelation

    # Đo độ tương quan của tín hiệu với chính nó ở các độ trễ khác nhau 
    # → quan trọng để xây dựng ma trận Toeplitz.

    # --- STEP 8: create Toeplitz matrix R [NxN]---
    ## TODO createToeplitzMatrix
    la   $a0, autocorr                  # load address của autocorr[]
    la   $a1, R                         # Toeplitz matrix base
    move $a2, $s2                       # N
    jal  createToeplitzMatrix
    # - Mỗi đường chéo có giá trị giống nhau
    # - Ma trận đối xứng

    # --- STEP 9: solveLinearSystem ---
    # TODO
    la   $a0, R                         # A = R (N x N, row-major)
    la   $a1, crosscorr                 # load address của vector b = crosscorr
    la   $a2, optimize_coefficient      # load address của vector x (output) = coeff[10]
    move $a3, $s2                       # lưu bản sao của N = 10
    jal  solveLinearSystem
    # optimize_coefficient[] chứa hệ số tối ưu của bộ lọc Wiener: h_opt = R^(-1) × crosscorr

    # --- STEP 10: applyWienerFilter ---
    # Áp dụng bộ lọc Wiener để tạo tín hiệu đầu ra đã lọc
    # output[n] = Σ(k=0 to n) optimize_coefficient[k] × input_signal[n-k]
    # TODO
    la   $a0, input_signal              # load address của x[n]
    la   $a1, optimize_coefficient      # load address của h[k]
    la   $a2, output_signal             # load address của y[n] 
    move $a3, $s2                       # N
    jal  applyWienerFilter
    j    exit_program

exit_program:

    
    # --- STEP 11: compute MMSE ---
    # Tính Mean Minimum Square Error
    # sai số bình phương trung bình giữa tín hiệu mong muốn và tín hiệu đã lọc
    # MMSE = (1/N) × Σ(i=0 to N-1) [desired_signal[i] - output_signal[i]]²
    #TODO
    la   $a0, desired_signal    # load address của desired_signal[]
    la   $a1, output_signal     # load address của output_signal[]
    move $a2, $s2               # N
    jal  computeMMSE            # mmse in $f0 and stored in variable

    # --- Open output file ---
    li   $v0, 13
    la   $a0, output_file           # "output.txt"
    li   $a1, 1                     # flags = 1 (write-only)
    li   $a2, 0
    syscall
    move $s0, $v0                   # save file descriptor in $s0 (callee-saved)

    # --- Write "Filtered output: " (in file)---
    la   $a0, header_filtered       # strlen takes arg in $a0  
    jal  strlen                     # gọi hàm strlen để đếm số kí tự trong "Filtered output: " => length: độ dài chuỗi 
    move $t3, $v0                   # write length vào $t3
    li   $v0, 15                    # write to file
    move $a0, $s0                   # fd 
    la   $a1, header_filtered       # buf (chuỗi cần ghi)
    move $a2, $t3                   # len (số byte cần ghi)
    syscall

    # --- "Filtered output: "  (in console) ---
    li   $v0, 4                     # print string
    la   $a0, header_filtered       # chuỗi "Filtered output: " cần in
    syscall

    # --- Write filtered outputs with 1 decimal AND print to terminal ---
    # pointer to output array - con trỏ đến phần tử đầu tiên của `output_signal[]
    la   $s4, output_signal        
    lw   $s5, NUM_SAMPLES           # count N

write_outputs_loop:
    beq  $s5, $zero, write_mmse_header      
    # nếu counter = 0 : đã ghi hết 10 số => nhảy đến write_mmse_header

    lwc1 $f12, 0($s4)               # load float từ output_signal[] vào $f12
    jal  round_to_1dec              # gọi hàm làm tròn đến 1 chữ số thập phân

    la    $a0, temp_str             # load buffer để lưu chuỗi
    mov.s $f12, $f0                 # copy gtri đã làm tròn sang $f12
    li    $a1, 1                    # decimals = 1 (1 chữ số thập phân)
    jal   float_to_str              # convert float -> string
    move  $t6, $v0                  # lưu độ dài chuỗi vào $t6

    # write number (file)
    li   $v0, 15                    # write
    move $a0, $s0                   # fd
    la   $a1, temp_str              # buffer chứa chuỗi 
    move $a2, $t6                   # độ dài chuỗi
    syscall

    # print number (console)
    li   $v0, 4
    la   $a0, temp_str
    syscall

    # advance to next element & decrement count
    addiu $s4, $s4, 4                   # next element
    addiu $s5, $s5, -1                  # --N

    # if this was the last element, don't print space
    # nếu vừa ghi phần tử cuối cùng ('\0') → không in dấu cách
    beq  $s5, $zero, write_mmse_header  

    # otherwise write space (file)
    li   $v0, 15
    move $a0, $s0
    la   $a1, space_str
    li   $a2, 1
    syscall

    # and print space (console)
    li   $v0, 11
    li   $a0, 32                        # ' '
    syscall

    j     write_outputs_loop

write_mmse_header:
    # --- Write "\nMMSE: " (file)---
    la   $a0, header_mmse               # "\nMMSE: "
    jal  strlen                         # tính độ dài
    move $t3, $v0
    li   $v0, 15
    move $a0, $s0                       # fd
    la   $a1, header_mmse
    move $a2, $t3
    syscall

    # --- "\nMMSE: " (console) ---
    li   $v0, 4
    la   $a0, header_mmse
    syscall

    # --- Write MMSE with 1 decimal to file + console ---
    lwc1 $f12, mmse                 # load gtri MMSE từ biến 
    jal  round_to_1dec              # làm tròn 1 chữ số thập phân

    # chuyển MMSE sang string 
    la    $a0, temp_str
    mov.s $f12, $f0                 # pass float (gtri đã làm tròn) via FP reg                                (FIX)
    li    $a1, 1                    # 1 decimal
    jal   float_to_str              
    move  $t6, $v0                  # save length again

    # write mmse (file)
    li   $v0, 15
    move $a0, $s0
    la   $a1, temp_str
    move $a2, $t6                   # use saved length
    syscall

    # print mmse (console)
    li   $v0, 4
    la   $a0, temp_str
    syscall

    # --- Close output file & exit ---
    li   $v0, 16
    move $a0, $s0
    syscall

    li   $v0, 10
    syscall

# -----------------------------------------------------------
# computeAutocorrelation(input_signal[], autocorr[], N)
# autocorr[k] = (1/N) * sum_{n=k..N-1} input_signal[n] * input_signal[n-k]

# Tự tương quan đo lường mức độ tương đồng của tín hiệu với chính nó 
# ở các độ trễ khác nhau.
# -----------------------------------------------------------
computeAutocorrelation:
    # $a0 = base input_signal
    # $a1 = base autocorr
    # $a2 = N
    addiu $sp, $sp, -16             # cấp phát 16 bytes trên stack
    sw    $ra, 12($sp)              # lưu return address
    
    # lưu các thanh ghi cần bảo toàn
    sw    $s0,  8($sp)
    sw    $s1,  4($sp)
    sw    $s2,  0($sp)

    move  $s0, $a0                  # load address của input_signal[]
    move  $s1, $a2                  # N
    move  $s2, $a1                  # load base address của autocorr[] (mảng đầu ra)

    # chuyển N sang float -> $f10
    mtc1  $s1, $f10
    cvt.s.w $f10, $f10              # convert int -> single-precision float

    # vòng lặp ngoài (k = 0 -> N-1): mỗi vòng lặp tính autocorr[k]
    li    $t0, 0                    # k = 0 (độ trễ từ 0 -> 9)
ac_k_loop:
    bge   $t0, $s1, ac_done         # Nếu k >= N => kết thúc

    # sum = 0.0
    la    $t3, zero_f               # load địa chỉ hằng số 0.0
    lwc1  $f0, 0($t3)               # $f0 = 0.0 (tích lũy tổng)

    # pA = signal + 0, pB = signal + k
    move  $t4, $s0                  # pA = input_signal[0] (bắt đầu từ ptu đầu tiên)
    sll   $t5, $t0, 2               # k*4 (offset byte)
    addu  $t6, $s0, $t5             # pB = input_signal[k] (bắt đầu từ ptu thứ k)

    # cnt = N - k: đếm số phép nhân cần thực hiện
    subu  $t7, $s1, $t0

    # vòng lặp trong: tính tích có hướng (dot product)
ac_dot_loop:
    beq   $t7, $zero, ac_store      # nếu cnt = 0 -> lưu kết quả

    lwc1  $f2, 0($t4)               # *pA = pointer to input_signal[n]
    lwc1  $f4, 0($t6)               # *pB = pointer to input_signal[n-k]
    mul.s $f6, $f2, $f4             # input[n] x input[n-k]
    add.s $f0, $f0, $f6             # sum += tích vừa tính

    addiu $t4, $t4, 4               # pA++ (tiến lên 4 byte cho ptu kế)
    addiu $t6, $t6, 4               # pB++ (tương tự)
    addiu $t7, $t7, -1              # cnt--
    j     ac_dot_loop

    # tính trung bình và lưu kết quả
ac_store:
    div.s $f8, $f0, $f10            # $f8 = sum / N (lấy trung bình)
    # autocorr[k]                   
    move  $t8, $s2                  # $t8 = địa chỉ autocorr[0]
    sll   $t9, $t0, 2               # $t9 = k x 4 (offset)
    addu  $t8, $t8, $t9             # $t8 = địa chỉ của autocorr[k]
    swc1  $f8, 0($t8)               # lưu autocorr[k] = $f8

    addiu $t0, $t0, 1               # k++
    j     ac_k_loop

ac_done:
    lw    $ra, 12($sp)              # khôi phục $ra
    lw    $s0,  8($sp)
    lw    $s1,  4($sp)
    lw    $s2,  0($sp)
    addiu $sp, $sp, 16              # thu hồi stack
    jr    $ra                       # trả về hàm gọi

# ---------------------------------------------------------
# computeCrosscorrelation(desired_signal[], input_signal[], crosscorr[], N)
# desired_signal[], input_signal[], N -> crosscorr[]
# crosscorr[k] = (1/N) * Σ(n=k to N-1) desired_signal[n] * input_signal[n-k]

# tính tương quan chéo (cross-correlation) 
# giữa tín hiệu mong muốn (desired_signal) và tín hiệu đầu vào (input_signal)
# => xác định mối quan hệ giữa hai tín hiệu
# ---------------------------------------------------------
computeCrosscorrelation:
    addiu $sp, $sp, -20             # cấp phát 20 byte do lần này cần thêm 1 thanh ghi
    sw    $ra, 16($sp)              # return address
    sw    $s0, 12($sp)              # desired_signal
    sw    $s1,  8($sp)              # input_signal
    sw    $s2,  4($sp)              # lưu N
    sw    $s3,  0($sp)              # Lưu crosscorr

    move  $s0, $a0                  # $s0 = base address của desired_signal []
    move  $s1, $a1                  # $s1 = base address của input_signal[]
    move  $s2, $a3                  # $s2 = N (số ptu)
    move  $s3, $a2                  # $s3 = base address của crosscorr[] (đầu ra)

    # float Nf
    mtc1  $s2, $f10                 # chuyển N vào FPU reg 
    cvt.s.w $f10, $f10              # int -> float

    # vòng lặp ngoài: từ k = 0 -> N-1 (độ trễ)
    li    $t0, 0                    # k = 0
xcorr_k_loop:
    bge   $t0, $s2, xcorr_end       # Nếu k >= N -> kết thúc

    la    $t3, zero_f
    lwc1  $f0, 0($t3)               # sum = 0.0 (tích lũy tổng)

    # vòng lặp trong từ n = k -> N-1 
    move  $t1, $t0                  # bắt đầu từ n = k
xcorr_n_loop:
    bge   $t1, $s2, xcorr_store     # Nếu n >= N => Lưu kết quả

    # tính desired_signal[n]
    mul   $t4, $t1, 4               # $t4 = n x 4 (offset byte)
    addu  $t5, $s0, $t4             # $t5 = địa chỉ của desired_signal[n]
    lwc1  $f2, 0($t5)               # $f2 = desired_signal[n]

    # tính input_signal[n-k]
    subu  $t6, $t1, $t0             # $t6 = n - k
    mul   $t7, $t6, 4               # $t7 = (n-k) x 4 (offset byte)
    addu  $t8, $s1, $t7             # $t8 = địa chỉ của input_signal[n-k]
    lwc1  $f4, 0($t8)               # $f4 = input_signal[n-k]

    # tính tích và cộng dồn
    mul.s $f6, $f2, $f4             # $f6 = desired[n] x input[n-k]
    add.s $f0, $f0, $f6             # sum += $f6

    addiu $t1, $t1, 1               # n++
    j     xcorr_n_loop              # lặp lại

    # tính trung bình và lưu kết quả
xcorr_store:
    div.s $f8, $f0, $f10            # $f8 = sum / N
    move  $t9, $s3                  # $t9 = địa chỉ của crosscorr[0]
    mul   $t2, $t0, 4               # $t2 = k x 4
    addu  $t9, $t9, $t2             # $t9 = địa chỉ của crosscorr[k]
    swc1  $f8, 0($t9)               # lưu crosscorr[k] = $f8

    addiu $t0, $t0, 1               # k++
    j     xcorr_k_loop

    # khôi phục và thoát
xcorr_end:
    lw    $ra, 16($sp)
    lw    $s0, 12($sp)
    lw    $s1,  8($sp)
    lw    $s2,  4($sp)
    lw    $s3,  0($sp)
    addiu $sp, $sp, 20
    jr    $ra

# giải thích cụ thể công thức của autocorrelation và crosscorrelation 
# và việc áp dụng các công thức đó vào đây như thế nào?

# ---------------------------------------------------------
# createToeplitzMatrix(autocorr[], R[][], N)
# autocorr[], N -> R[N][N] (row-major)
# R[i][j] = autocorr[abs(i - j)]

# xây dựng ma trận Toeplitz từ vector autocorrelation:
# mỗi đường chéo từ trái-trên xuống phải-dưới có giá trị giống nhau, và ma trận này đối xứng.
# ---------------------------------------------------------
createToeplitzMatrix:
    addiu $sp, $sp, -20
    sw    $ra, 16($sp)
    sw    $s0, 12($sp)              # lưu autocorr[] (do ma trận này dc tạo từ autocorr[])
    sw    $s1,  8($sp)              # lưu R[][]
    sw    $s2,  4($sp)              # Lưu N
    sw    $s3,  0($sp)              # dự phòng

    # sao chép các tham số
    move  $s0, $a0                  # địa chỉ autocorr[]
    move  $s1, $a1                  # địa chỉ R[][]
    move  $s2, $a2                  # N (kích thước ma trận NxN)

    # vòng lặp ngoài (duyệt hàng i)
    li    $t0, 0                    # i = 0 (chỉ số hàng)
tp_i_loop:
    bge   $t0, $s2, tp_done         # i >= N => done

    # tính địa chỉ đầu hàng: base_row = &R[i][0] = R + i*N
    move  $t4, $s1                  # địa chỉ R[0][0]
    mul   $t5, $t0, $s2             # i x N (số ptu trc hàng i)
    sll   $t5, $t5, 2               # (i x N) x 4 (offset)

    # R[i][j] nằm ở vị trí: base + (i×N + j)×4
    addu  $t4, $t4, $t5             # địa chỉ R[i][0]

    # Chỉ tính nửa trên ma trận (j ≥ i), sau đó sao chép xuống nửa dưới (đối xứng).
    move  $t1, $t0                  # j = i (chỉ duyệt nửa trên + đường chéo)
tp_j_loop:
    bge   $t1, $s2, tp_next_i       # Nếu j >= N → sang hàng tiếp

    # Tính chỉ số autocorrelation: idx = j - i
    subu  $t2, $t1, $t0             # $t2 = j - i (luôn ≥ 0 vì j ≥ i)
    move  $t6, $s0                  # $t6 = địa chỉ autocorr[0]
    sll   $t7, $t2, 2               # $t7 = (j-i) × 4 (offset)

    addu  $t6, $t6, $t7             # $t6 = địa chỉ autocorr[j-i]
    lwc1  $f0, 0($t6)               # $f0 = autocorr[j-i]

    # Gán giá trị cho phần tử phía trên (upper triagle): R[i][j]
    sll   $t8, $t1, 2               # $t8 = j × 4 (offset trong hàng i)
    addu  $t9, $t4, $t8             # $t9 = địa chỉ R[i][j] (base_row + j×4)
    swc1  $f0, 0($t9)               # R[i][j] = autocorr[j-i]

    # Gán giá trị đối xứng cho phần tử phía dưới (lower mirror): R[j][i] if j != i
    beq   $t1, $t0, tp_next_j       # Nếu i = j (đường chéo) → bỏ qua

    move  $t3, $s1                  # địa chỉ R base (R[0][0])
    mul   $t5, $t1, $s2             # j*N
    addu  $t5, $t5, $t0             # j*N + i (chỉ số 1D của R[j][i])
    sll   $t5, $t5, 2               # $t5 = (j×N + i) × 4 (offset byte)
    addu  $t3, $t3, $t5             # $t3 = địa chỉ R[j][i]
    swc1  $f0, 0($t3)               # R[j][i] = autocorr[j-i] (đối xứng)

    # cần kiểm tra i == j vì đường chéo chính chỉ cần gán 1 lần (ko đối xứng với chính nó)

tp_next_j:
    # Tăng j và lặp lại
    addiu $t1, $t1, 1               # j++
    j     tp_j_loop

tp_next_i:
    # Tăng i và lặp lại
    addiu $t0, $t0, 1               # i++
    j     tp_i_loop

    # Khôi phục và thoát
tp_done:
    lw    $ra, 16($sp)
    lw    $s0, 12($sp)
    lw    $s1,  8($sp)
    lw    $s2,  4($sp)
    lw    $s3,  0($sp)
    addiu $sp, $sp, 20
    jr    $ra

# ---------------------------------------------------------
# solveLinearSystem(A[][], b[], x[], N)
# Thực hiện khử Gauss có chọn phần tử trụ theo cột (partial pivot)
# A: $a0, b: $a1, x(out): $a2, N: $a3
# Dùng buffer 'aug' kích thước N x (N+1)

# Uses an augmented matrix aug[N][N+1] but addresses rows with
#   row_base = &aug[i][0]  (row-major)
# Then inner loops do row_base + j*4 pointer walks -> readable.

# Phương trình cần giải: R × h_opt = γ_d
# Trong đó:
# - R: Ma trận Toeplitz (10×10) - autocorrelation (A)
# - γ_d: Vector (10×1) - crosscorrelation (b)
# - h_opt: Vector (10×1) - hệ số tối ưu CẦN TÌM (x)
# ---------------------------------------------------------
solveLinearSystem:
    addiu $sp, $sp, -40             # cấp phát 40 byte stack
    sw    $ra, 36($sp)              # return address
    sw    $s0, 32($sp)              # A (ma trận hệ Số)
    sw    $s1, 28($sp)              # b (vector vế phải)
    sw    $s2, 24($sp)              # x (vector nghiệm - output)
    sw    $s3, 20($sp)              # N (kích thước = 10)
    sw    $s4, 16($sp)              # (N+1) = 11
    sw    $s5, 12($sp)
    sw    $s6,  8($sp)
    sw    $s7,  4($sp)

    move  $s0, $a0
    move  $s1, $a1
    move  $s2, $a2
    move  $s3, $a3

    addiu $s4, $s3, 1               # $s4 = (N+1) = 11 (số cột của aug)

    # 1. Build augmented matrix [A|b] (ma trận mở rộng): cấu trúc aug[10][11] do có thêm vector vế phải b
    
    # copy A into aug[][0..N-1], b into aug[][N]
    # Vòng lặp chính - Duyệt từng hàng
    li    $t0, 0                    # i = 0 (chỉ số hàng)
build_i:
    bge   $t0, $s3, fwd_elim        # if (i >= N): sang forward elimination

    # tính địa chỉ đầu hàng i: row_base_aug = &aug[i][0]
    mul   $t1, $t0, $s4             # $t1 = i × (N+1) = i × 11
    sll   $t1, $t1, 2               # $t1 = (i × 11) × 4 (offset byte)
    la    $t2, aug                  # Load base address của augmented
    addu  $t2, $t2, $t1             # $t2 = địa chỉ của aug[i][0]

    # copy hàng thứ i từ A vào aug: j = 0..N-1
    li    $t3, 0                    # j = 0 (chỉ số cột)
copy_A_j:
    bge   $t3, $s3, copy_b          # if (j >= N) → copy b
    # Tính A[i][j]
    mul   $t4, $t0, $s3             # $t4 = i × N
    addu  $t4, $t4, $t3             # $t4 = i×N + j (chỉ số 1D)
    sll   $t4, $t4, 2               # $t4 = (i×N + j) × 4
    addu  $t5, $s0, $t4             # $t5 = địa chỉ A[i][j]
    lwc1  $f0, 0($t5)               # Load gtri A[i][j]
    
    # lưu vào aug[i][j]
    sll   $t6, $t3, 2               # $t6 = j × 4
    addu  $t7, $t2, $t6             # $t7 = địa chỉ aug[i][j]
    swc1  $f0, 0($t7)               # aug[i][j] = A[i][j]
    addiu $t3, $t3, 1               # j++
    j     copy_A_j

    # Copy b[i] vào cột cuối
copy_b:
    # aug[i][N] = b[i]
    sll   $t4, $t0, 2               # $t4 = i × 4
    addu  $t5, $s1, $t4             # $t5 = địa chỉ b[i]
    lwc1  $f2, 0($t5)               # load gtri b[i]
    sll   $t6, $s3, 2               # $t6 = N*4
    addu  $t7, $t2, $t6             # row_base_aug + N*4 => $t7 = &aug[i][N]
    swc1  $f2, 0($t7)               # aug[i][N] = b[i]

    addiu $t0, $t0, 1               # i++
    j     build_i

    # 2. Forward elimination with partial pivoting on 'aug'

    # Khử Gauss Xuôi với Chọn Phần Tử Trụ
    # Vòng lặp chính - Xử lý cột i
fwd_elim:
    li    $t0, 0                    # i = 0 (cột đang xử lý)
fe_i:
    bge   $t0, $s3, back_sub        # if (i >= N) → back substitution

    # Find pivot row (tìm hàng k có max |aug[k][i]|, k>=i)
    move  $t8, $t0                  # maxRow = i (giả sử pivot ở hàng i)
    addiu $t1, $t0, 0               # k = i (bắt đầu tìm từ hàng i)
find_piv:
    bge   $t1, $s3, piv_done        # if (k >= N) → done

    # Tính |aug[k][i]|
    mul   $t2, $t1, $s4             # $t2 = k × (N+1)
    sll   $t2, $t2, 2               # $t2 = k × (N+1) × 4
    la    $t3, aug                  
    addu  $t3, $t3, $t2             # row_base_k: $t3 = địa chỉ aug[k][0]
    sll   $t4, $t0, 2               # $t4 = i×4
    addu  $t5, $t3, $t4             # địa chỉ của aug[k][i]
    lwc1  $f0, 0($t5)               # $f0 = aug[k][i]
    abs.s $f0, $f0                  # $f0 = |aug[k][i]|

    # So sánh với |aug[maxRow][i]|
    mul   $t6, $t8, $s4             
    sll   $t6, $t6, 2
    la    $t7, aug
    addu  $t7, $t7, $t6             # $t7 = địa chỉ aug[maxRow][0]
    addu  $t9, $t7, $t4             # $t9 = địa chỉ aug[maxRow][i]
    lwc1  $f2, 0($t9)               # $f2 = aug[maxRow][i]
    abs.s $f2, $f2                  # $f2 = |aug[maxRow][i]|

    c.lt.s $f2, $f0                 # if (|aug[maxRow][i]| < |aug[k][i]|)
    bc1t   piv_upd                  # → cập nhật maxRow = k
    j      piv_next

piv_upd:
    move  $t8, $t1                  # maxRow = k
piv_next:
    addiu $t1, $t1, 1               # k++
    j     find_piv
    # Kết quả: $t8 chứa chỉ số hàng có phần tử trụ lớn nhất

piv_done:

    # Swap rows i <-> maxRow across columns 0..N
    beq   $t8, $t0, no_swap         # if (maxRow == i) → không cần swap

    # Tính địa chỉ 2 hàng: row_base_i / row_base_max 
    # => chuyển đổi chỉ số 2D → địa chỉ bộ nhớ 1D
    # tính địa chỉ hàng i (row_base_i)
    mul   $t2, $t0, $s4             # số ptu trc hàng i: $t2 = i × (N+1)
    sll   $t2, $t2, 2               # offset
    la    $t3, aug                  
    # Địa chỉ aug[i][j] = base_address + (i × số_cột + j) × kích_thước_phần_tử
    addu  $t3, $t3, $t2             # $t3 = địa chỉ aug[i][0]
    
    # tính địa chỉ hàng maxRow (row_base_max)
    mul   $t6, $t8, $s4             # $t6 = maxRow × (N+1)
    sll   $t6, $t6, 2
    la    $t7, aug
    addu  $t7, $t7, $t6             # $t7 = địa chỉ aug[maxRow][0]

    # Hoán đổi toàn bộ hàng i với hàng maxRow trong ma trận aug, từng cột một.
    # đưa phần tử trụ (pivot) lớn nhất lên hàng i, tránh chia cho số quá nhỏ
    li    $t1, 0                    # col = 0 xét đến N
swap_cols:
    bgt   $t1, $s3, no_swap         # if (col > N) → done (swap cả 11 cột)
    sll   $t4, $t1, 2
    addu  $t5, $t3, $t4             # $t5 = &aug[i][col]
    addu  $t9, $t7, $t4             # $t9 = &aug[maxRow][col]

    lwc1  $f0, 0($t5)               # $f0 = aug[i][col] = temp
    lwc1  $f2, 0($t9)               # $f2 = aug[maxRow][col]
    swc1  $f0, 0($t9)               # aug[maxRow][col] = temp
    swc1  $f2, 0($t5)               # aug[i][col] = aug[maxRow][col]
    addiu $t1, $t1, 1               # col++
    j     swap_cols
no_swap:

    # Khử Gauss (forward elimination)
    # Eliminate rows k = i+1..N-1: 
    # => Biến đổi ma trận aug thành ma trận tam giác trên (upper triangular)
    # => Biến aug[k][i] = 0 với mọi k > i
    # CÁCH LÀM: Trừ hàng k đi một bội số của hàng i để aug[k][i] = 0
    # factor = aug[k][i] / aug[i][i]
    # aug[k][j] = aug[k][j] - factor × aug[i][j]  (với mọi j từ i đến N)
    addiu $t1, $t0, 1               # k = i+1 (bắt đầu từ hàng dưới)
elim_k:
    bge   $t1, $s3, fe_next_i       # k >= N ? done for this i

    # Bước 1: Tính địa chỉ đầu 2 hàng
    # row_base_i (hàng pivot - hàng chuẩn)
    mul   $t2, $t0, $s4             # $t2 = i × (N+1)
    sll   $t2, $t2, 2               # $t2 = i × (N+1) × 4 (offset byte)
    la    $t3, aug
    addu  $t3, $t3, $t2             # # $t3 = &aug[i][0]

    # row_base_k (hàng cần khử)
    mul   $t6, $t1, $s4             # $t6 = k × (N+1)
    sll   $t6, $t6, 2               # $t6 = k × (N+1) × 4
    la    $t7, aug
    addu  $t7, $t7, $t6             # $t7 = &aug[k][0]

    # Bước 2: Tính hệ số khử factor = aug[k][i] / aug[i][i]
    sll   $t4, $t0, 2               # $t4 = i × 4 (offset cột i)
    addu  $t5, $t7, $t4             # $t5 = &aug[k][i]
    lwc1  $f4, 0($t5)               # $f4 = aug[k][i] (tử số)

    addu  $t9, $t3, $t4             # $t9 = &aug[i][i] (pivot)
    lwc1  $f6, 0($t9)               # $f6 = aug[i][i] (mẫu số)
    div.s $f8, $f4, $f6             # $f8 = factor = aug[k][i] / aug[i][i]

    # khử từng ptu trong hàng k
    # for col j = i..N: aug[k][j] -= factor * aug[i][j] (Hàng k cần trừ đi factor lần hàng i)
    sll   $t9, $t0, 2               # $t9 = offset = i*4 (bắt đầu từ cột i)
    # Các cột j < i đã bị khử về 0 ở các bước trước
    # Chỉ cần xử lý từ cột i trở đi (bao gồm cột b ở cuối)

    # vòng lặp khử từng cột
elim_cols:
    sll   $t6, $s3, 2               # N*4 (last column index)
    bgt   $t9, $t6, fe_next_k       # if offset > N*4 -> done (đã khử hết)

    addu  $t5, $t7, $t9             # $t5 = &aug[k][j]
    lwc1  $f0, 0($t5)               # $f0 = aug[k][j] (gtri cũ)

    addu  $t4, $t3, $t9             # $t4 = &aug[i][j]
    lwc1  $f2, 0($t4)               # $f2 = aug[i][j]

    mul.s $f10, $f8, $f2            # $f10 = factor × aug[i][j]
    sub.s $f12, $f0, $f10           # $f12 = aug[k][j] - factor × aug[i][j]
    swc1  $f12, 0($t5)              # Lưu kết quả mới vào aug[k][j]

    addiu $t9, $t9, 4               # next column
    j     elim_cols

fe_next_k:
    addiu $t1, $t1, 1               # k++ (hàng tiếp theo)
    j     elim_k                    # khử hàng k tiếp theo

fe_next_i:
    addiu $t0, $t0, 1               # i++ (cột tiếp theo)
    j     fe_i                      # xử lý cột i tiếp theo

    # 3. Back substitution on 'aug' (Thế ngược):
    # Tính nghiệm x[i] từ ma trận tam giác trên, từ dưới lên (i = N-1 → 0)
    # x[i] = (aug[i][N] - Σ(j=i+1 to N-1) aug[i][j] × x[j]) / aug[i][i]
back_sub:
    addiu $t0, $s3, -1              # i = N-1 (bắt đầu từ hàng cuối)
    # Hàng cuối chỉ có 1 ẩn: aug[9][9] × x[9] = aug[9][10]
    # → x[9] = aug[9][10] / aug[9][9] (tính trực tiếp)
    # Dùng x[9] đã biết để tính x[8], x[7], ..., x[0]

bs_i:
    bltz  $t0, aug_done             # if (i < 0) => done

    # tính địa chỉ đầu hàng i: row_base_i
    mul   $t1, $t0, $s4             # $t1 = i × (N+1)
    sll   $t1, $t1, 2               # $t1 = i × (N+1) × 4
    la    $t2, aug
    addu  $t2, $t2, $t1             # $t2 = &aug[i][0]

    # sum = aug[i][N]
    sll   $t3, $s3, 2               # N*4 (offset cột N)
    addu  $t4, $t2, $t3             # $t4 = &aug[i][N]
    lwc1  $f0, 0($t4)               # $f0 = aug[i][N] (khởi tạo sum)

    # Trừ đi các thành phần đã bt: sum -= aug[i][j]*x[j], j=i+1..N-1
    addiu $t5, $t0, 1               # j = i+1 (bắt đầu từ cột sau i)

    # Vòng lặp j từ i+1 đến N-1:
bs_j:
    bge   $t5, $s3, bs_write        # if (j >= N) → viết x[i]
    sll   $t6, $t5, 2               # offset
    addu  $t7, $t2, $t6             # $t7 = &aug[i][j]
    lwc1  $f2, 0($t7)               # $f2 = aug[i][j] (hệ số)

    # load hệ số
    sll   $t8, $t5, 2               # offset
    addu  $t9, $s2, $t8             # $t9 = &x[j]
    lwc1  $f4, 0($t9)               # $f4 = x[j] (nghiệm đã tính)

    # load x[j] từ vector nghiệm
    mul.s $f6, $f2, $f4             # $f6 = aug[i][j] × x[j]
    sub.s $f0, $f0, $f6             # sum -= aug[i][j] × x[j]

    addiu $t5, $t5, 1               # j++
    j     bs_j                      # lặp lại

    # tính và lưu x[i]
bs_write:
    # x[i] = sum / aug[i][i] (Chia cho hệ số đường chéo)
    sll   $t6, $t0, 2
    addu  $t7, $t2, $t6             # $t7 = &aug[i][i]
    lwc1  $f8, 0($t7)               # $f8 = aug[i][i] (hệ số đường chéo)
    div.s $f10, $f0, $f8            # $f10 = sum / aug[i][i]

    # Lưu nghiệm vào vector x[]
    sll   $t8, $t0, 2
    addu  $t9, $s2, $t8             # $t9 = &x[i]
    swc1  $f10, 0($t9)              # x[i] = result

    addiu $t0, $t0, -1              # i-- (lùi lên hàng trên)
    j     bs_i                      # tình x[i-1]

    # khôi phục và thoát
aug_done:
    lw    $ra, 36($sp)
    lw    $s0, 32($sp)
    lw    $s1, 28($sp)
    lw    $s2, 24($sp)
    lw    $s3, 20($sp)
    lw    $s4, 16($sp)
    lw    $s5, 12($sp)
    lw    $s6,  8($sp)
    lw    $s7,  4($sp)
    addiu $sp, $sp, 40
    jr    $ra

# ---------------------------------------------------------
# applyWienerFilter(input_signal[], optimize_coefficient[], output[], N)
# output[n] = Σ(k=0 to n) optimize_coefficient[k] * input_signal[n-k]
# input_signal:  $a0, optimize_coefficient: $a1, output: $a2, N: $a3
# áp dụng bộ lọc Wiener để tạo tín hiệu đầu ra đã lọc từ tín hiệu đầu vào nhiễu.
# For each n: walk ptrA over optimize_coefficient[0..n] and ptrB over input_signal[n..0]
# (they meet in the middle), accumulating dot product.
# ---------------------------------------------------------
applyWienerFilter:
    # phép tích chập (convolution) trong xử lý tín hiệu: 
    # Mỗi mẫu đầu ra là tổng trọng số của các mẫu đầu vào trước đó (Trọng số = hệ số tối ưu từ bộ lọc Wiener)
    addiu $sp, $sp, -20
    sw    $ra, 16($sp)
    sw    $s0, 12($sp)                  # base address input_signal[]
    sw    $s1,  8($sp)                  # base address optimize_coefficient[]
    sw    $s2,  4($sp)                  # base address output_signal[]
    sw    $s3,  0($sp)                  # N

    # sao chép tham số 
    move  $s0, $a0
    move  $s1, $a1
    move  $s2, $a2
    move  $s3, $a3

    # vòng lặp ngoài - duyệt từng mẫu đầu ra
    li    $t0, 0                        # n = 0 (chỉ số mẫu đầu ra)
af_n:
    bge   $t0, $s3, af_done             # if (n >= N) => done

    # tổng tích lũy sum = 0.0
    la    $t4, zero_f
    lwc1  $f0, 0($t4)                   # $f0 = 0.0 (tích lũy tổng cho output[n])

    # ptrA = &optimize_coefficient[0]; ptrB = &input_signal[n]
    # Iteration k:
    # ptrA → optimize_coefficient[k]      (đi xuôi: 0→n)
    # ptrB → input_signal[n-k]            (đi ngược: n→0)
    move  $t5, $s1                      # ptrA → coeff[0]
    sll   $t6, $t0, 2                   # offset = n × 4
    addu  $t7, $s0, $t6                 # ptrB = input_signal + n*4

    # vòng lặp tính tích chập (k)
    # loop k = 0..n: (advance ptrA forward, ptrB backward)
    li    $t1, 0                        # k = 0
af_k:
    bgt   $t1, $t0, af_store            # if (k > n) → lưu kết quả

    # lấy giá trị từ bộ nhớ
    lwc1  $f2, 0($t5)                   # optimize_coefficient[k]
    lwc1  $f4, 0($t7)                   # input_signal[n-k]
    # Tính tích và cộng dồn
    mul.s $f6, $f2, $f4                 # $f6 = coeff[k] × input[n-k]
    add.s $f0, $f0, $f6                 # sum += tích vừa tính

    addiu $t5, $t5, 4                   # ++ptrA (tiến tới coeff[k+1])
    addiu $t7, $t7, -4                  # --ptrB (lùi về input[n-k-1])
    addiu $t1, $t1, 1                   # k++
    j     af_k                          # lặp lại

af_store:
    sll   $t2, $t0, 2                   # offset = n × 4
    addu  $t3, $s2, $t2                 # địa chỉ output[n]
    swc1  $f0, 0($t3)                   # output[n] = sum

    addiu $t0, $t0, 1                   # n++
    j     af_n                          # Tính output[n+1]

    # Khôi phục và trả về
af_done:
    lw    $ra, 16($sp)
    lw    $s0, 12($sp)
    lw    $s1,  8($sp)
    lw    $s2,  4($sp)
    lw    $s3,  0($sp)
    addiu $sp, $sp, 20
    jr    $ra

# ---------------------------------------------------------
# computeMMSE(desired_signal[], output[], N) -> $f0
# $a0 = desired_signal, $a1 = output, $a2 = N
# tính Mean Minimum Square Error (MMSE):
# sai số bình phương trung bình giữa tín hiệu mong muốn và tín hiệu đã lọc.
# MMSE = (1/N) × Σ[i=0 to N-1] (desired_signal[i] - output_signal[i])²
# ---------------------------------------------------------
computeMMSE:
    addiu $sp, $sp, -16             # cấp phát 16 byte trên stack
    sw    $ra, 12($sp)              # return address
    sw    $s0,  8($sp)              # lưu $s0 (calle-saved reg)
    sw    $s1,  4($sp)              # $s1
    sw    $s2,  0($sp)              # $s2

    # sao chép tham số
    move  $s0, $a0                  # desired_signal base address
    move  $s1, $a1                  # output_signal base address
    move  $s2, $a2                  # N

    # biến tổng tích lũy các sai số bình phương mmse_sum ($f0) = 0.0
    la    $t0, zero_f
    lwc1  $f0, 0($t0)

    # vòng lặp tính tổng sai số bình phương 
    li    $t1, 0                    # i = 0 (chỉ số mảng)
mmse_loop:
    bge   $t1, $s2, mmse_end        # i >= N: go to mmse_end (khi duyệt 10 ptu thì dừng)

    sll   $t2, $t1, 2               # $ t2 = i x 4 (offset: 1 float = 4 byte)
    addu  $t3, $s0, $t2             # địa chỉ desired_signal[i]
    addu  $t4, $s1, $t2             # địa chỉ output_signal[i]
    lwc1  $f2, 0($t3)               # desired_signal[i]
    lwc1  $f4, 0($t4)               # output[i]

    sub.s $f6, $f2, $f4             # $f6 = desired[i] - output[i] (error)
    mul.s $f8, $f6, $f6             # $f8 = (error)^2 (bình phương sai số)
    add.s $f0, $f0, $f8             # sum += e^2

    # tăng chỉ số và lặp lại
    addiu $t1, $t1, 1               # i++
    j     mmse_loop                 # lặp lại

mmse_end:
    # tính trung bình (mean)
    mtc1  $s2, $f10
    cvt.s.w $f10, $f10              # int -> float
    div.s $f0, $f0, $f10            # $f0 = mmse = sum / N

    # save to variable mmse (lưu kq vào biến toàn cục)
    la    $t5, mmse
    swc1  $f0, 0($t5)

    # Khôi phục và trả về hàm gọi 
    lw    $ra, 12($sp)
    lw    $s0,  8($sp)
    lw    $s1,  4($sp)
    lw    $s2,  0($sp)
    addiu $sp, $sp, 16
    jr    $ra

# --------- HELPER FUNCTION -------------------------------
# strlen($a0 = asciiz) -> $v0 length (no NUL)
# đếm độ dài chuỗi
# ---------------------------------------------------------
strlen:
    move  $t0, $a0                      # con trỏ chuỗi
strlen_loop:
    lb    $t1, 0($t0)                   # load 1 byte
    beq   $t1, $zero, strlen_done       # Nếu '\0' => done (ko tính)
    addiu $t0, $t0, 1                   # tăng con trỏ (di chuyển đến ptu kế tiếp)
    j     strlen_loop
strlen_done:
    # $v0 = độ dài = (con trỏ cuối - con trỏ đầu)
    subu  $v0, $t0, $a0                 
    jr    $ra

# ---------------------------------------------------------
# round_to_1dec($f12) -> $f0
# rounds to one decimal: nearest-even is not required here;
# we use +/-0.5 after scaling by 10.
# ---------------------------------------------------------
# f0 = round(f12 to 1 decimal)
# rounds to one decimal by using truncation and scaling.
# ---------------------------------------------------------
# Thuật toán:
# Nhân với 10 → value × 10
# Cộng/trừ 0.5 (tùy dấu) → scaled ± 0.5
# Cắt phần thập phân → trunc(scaled ± 0.5)
# Chia 10 → result / 10
# ---------------------------------------------------------
round_to_1dec:
    # Dịch chuyển 1 chữ số thập phân lên hàng đơn vị
    lwc1  $f2, ten                  # f2 = 10.0
    mul.s $f3, $f12, $f2            # f3 = value * 10 (scaling)

    lwc1  $f0, zero_f               # 0.0 in a FP reg (needed for compare)
    lwc1  $f5, half                 # 0.5 (used for rounding)
    c.lt.s $f3, $f0                 # So sánh: $f3 < 0.0 ?
    bc1t  rt1_neg                   # Nếu âm → nhảy đến rt1_neg
    add.s $f3, $f3, $f5             # Số dương: $f3 += 0.5 (for rounding)
    j     rt1_to_int                # Nhảy đến bước cắt
rt1_neg:
    sub.s $f3, $f3, $f5             # Số âm: $f3 -= 0.5 (for rounding)

    # Cắt phần thập phân (truncation), giữ phần nguyên
rt1_to_int:
    trunc.w.s $f4, $f3              # f4 = trunc($f3) - truncated value (no rounding here): cắt -> int
    cvt.s.w $f4, $f4                # convert int to float
    div.s  $f0, $f4, $f2            # $f0 = $f4 / 10.0
    jr $ra                          #  return 

# ---------------------------------------------------------
# float_to_str(buffer $a0, value $f12, decimals $a1) -> length $v0
# - Writes optional '-' sign
# - Writes integer part in base-10
# - If decimals > 0, writes '.' then exactly 'decimals' digits
#   (uses the value already rounded as needed by caller)
# Notes:
#   - Handles 0, negative numbers, zero-padding for 2 decimals (e.g., 0.05)
# ---------------------------------------------------------
# float_to_str(buffer $a0, value $f12, decimals $a1) -> length $v0
float_to_str:
    addiu $sp, $sp, -48
    sw    $ra, 44($sp)              # return address
    sw    $s0, 40($sp)              # buf start (địa chỉ đầu buffer)
    sw    $s1, 36($sp)              # buf cur (con trỏ hiện tại trong buffer)
    sw    $s2, 32($sp)              # decimals (số chữ số thập phân)
    sw    $s3, 28($sp)              # tmp
    sw    $s4, 24($sp)              # tmp
    sw    $s5, 20($sp)              # tmp
    sw    $s6, 16($sp)              # tmp
    sw    $s7, 12($sp)              # tmp

    # sao chép tham số
    move  $s0, $a0                  # địa chỉ đầu buffer
    move  $s1, $a0                  # con trỏ hiện tại (bắt đầu = đầu buffer)
    move  $s2, $a1                  # decimals 

    # sign handling: if value < 0, write '-' then negate
    lwc1  $f0, zero_f               # load 0.0 into $f0
    c.lt.s $f12, $f0                # So sánh: $f12 < 0.0 ?
    bc1f  ft_pos                    # Nếu >= 0 → số dương, nhảy đến ft_pos

    # Nếu là số âm:
    li    $t0, 45                   # ASCII '-'
    sb    $t0, 0($s1)               # Ghi '-' vào buffer
    addiu $s1, $s1, 1               # Tăng con trỏ buffer
    neg.s $f12, $f12                # Đổi dấu: $f12 = -$f12 (làm thành số dương)

    # tách phần nguyên và phần thập phân
ft_pos:
    # integer part: intp = (int) value
    cvt.w.s $f2, $f12               # $f2 = (int) $f12 (convert float → word)
    mfc1  $t1, $f2                  # intp in $t1 (move từ FPU → CPU)

    # fractional part: frac = value - float(intp)
    cvt.s.w $f3, $f2                # $f3 = (float) intp
    sub.s $f4, $f12, $f3            # $f4 = frac = value - intp

    # write integer digits
    move  $t2, $t1                      # work = intp
    # Kiểm tra phần nguyên có phải 0 không
    beq   $t2, $zero, ft_write_zero     # Nếu intp = 0 → ghi "0"

    # reverse-collect digits into temp_str
    la    $t3, str_buf              # địa chỉ buffer tạm (str_buf)
    move  $t4, $t3                  # $t4 = rev_ptr (con trỏ trong buffer tạm)

ft_int_rev_loop:
    beq   $t2, $zero, ft_int_rev_done   # Nếu work = 0 → xong
    li    $t5, 10                       
    div   $t2, $t5                      # Chia cho 10
    mfhi  $t6                           # digit = work % 10 (chữ số cuối)
    mflo  $t2                           # work = work / 10 (bỏ chữ số cuối)
    addiu $t6, $t6, 48                  # Convert digit → ASCII ('0' + digit)
    sb    $t6, 0($t4)                   # Lưu vào buffer tạm
    addiu $t4, $t4, 1                   # Tăng con trỏ buffer tạm
    j     ft_int_rev_loop

ft_int_rev_done:
    # copy back in forward order to output buffer
ft_copy_rev:
    beq   $t3, $t4, ft_after_int        # Nếu đã copy hết → xong
    addiu $t4, $t4, -1                  # Lùi con trỏ buffer tạm
    lb    $t7, 0($t4)                   # Load ký tự
    sb    $t7, 0($s1)                   # Ghi vào buffer đầu ra
    addiu $s1, $s1, 1                   # Tăng con trỏ đầu ra
    j     ft_copy_rev

    # TRƯỜNG HỢP PHẦN NGUYÊN = 0
ft_write_zero:
    li    $t7, 48                       # ASCII '0'
    sb    $t7, 0($s1)                   # Ghi '0'
    addiu $s1, $s1, 1                   # Tăng con trỏ

    # Ghi phần thập phận
ft_after_int:
    # if decimals == 0 -> done
    beq   $s2, $zero, ft_done

    # write '.'
    li    $t7, 46                       # ASCII '.'
    sb    $t7, 0($s1)                   # Ghi '.'
    addiu $s1, $s1, 1                   # Tăng con trỏ 

    # decimals == 1 ?
    li    $t0, 1
    beq   $s2, $t0, ft_frac_1

ft_frac_1:
    # Recompute the fractional digit from the FULL value in $f12 (đã được làm tròn bởi round_to_1dec)
    # using rounding: digit = round(value * 10) % 10

    # scaled = value * 10 (Dịch chuyển chữ số thập phân lên hàng đơn vị)
    lwc1  $f6, ten
    mul.s $f6, $f12, $f6                # $f6 = $f12 × 10

    # làm tròn scaled += 0.5  (value is already non-negative here do đã xử lý dấu)
    lwc1  $f7, half
    add.s $f6, $f6, $f7

    # convert sang int
    # scaled_int = (int) scaled
    cvt.w.s $f6, $f6
    mfc1    $t8, $f6                    # scaled_int >= 0

    # Lấy chữ số thập phân frac_digit = scaled_int % 10 (lấy phần dư của phép chia)
    li      $t9, 10
    div     $t8, $t9
    mfhi    $t8                         # $t8 = frac_digit = scaled_int % 10

    # write '0' + frac_digit (Convert sang ASCII và ghi vào buffer)
    addiu   $t8, $t8, 48                # $t8 = $t8 + 48 (convert → ASCII)
    sb      $t8, 0($s1)                 # Store byte vào buffer
    addiu   $s1, $s1, 1                 # Tăng con trỏ buffer
    j       ft_done                     # Nhảy đến kết thúc

ft_done:
    # null-terminate (handy for debugging; write syscall ignores it)
    li    $t0, 0
    sb    $t0, 0($s1)                   # Ghi '\0' 

    # tính độ dài chuỗi: length = cursor - start
    subu  $v0, $s1, $s0

    # khôi phục stack
    lw    $ra, 44($sp)
    lw    $s0, 40($sp)
    lw    $s1, 36($sp)
    lw    $s2, 32($sp)
    lw    $s3, 28($sp)
    lw    $s4, 24($sp)
    lw    $s5, 20($sp)
    lw    $s6, 16($sp)
    lw    $s7, 12($sp)
    addiu $sp, $sp, 48
    jr    $ra

# ---------- SIZE MISMATCH HANDLER --------------------------------
# Called only from parse_desired_done when input and desired sizes differ
# Trường hợp lỗi:
# count_input ≠ count_desired (VD: input có 10 số, desired có 8 số)
# count_input = count_desired = 0 (cả 2 file rỗng hoặc parse thất bại)
# Writes "Error: size not match" to output.txt and exits.
# -----------------------------------------------------------------
size_mismatch:
    # Open output.txt for writing
    li   $v0, 13                        # sys_open
    la   $a0, output_file               # "output.txt"
    li   $a1, 1                         # flag = write-only
    li   $a2, 0
    syscall
    move $s0, $v0                       # file descriptor

    bltz $s0, size_mismatch_exit        # if open failed, exit

    # Compute length of error string
    la   $a0, error_size_str            # Load địa chỉ "Error: size not match"
    jal  strlen                         # Gọi hàm strlen: $v0 = length
    move $t3, $v0                       # $t3 = độ dài chuỗi (không tính '\0')

    # Write "Error: size not match\n"
    li   $v0, 15                        # sys_write
    move $a0, $s0                       # fd
    la   $a1, error_size_str            # địa chỉ buffer cần ghi
    move $a2, $t3                       # số byte cần ghi
    syscall

    # Print the same message to the terminal
    li   $v0, 4
    la   $a0, error_size_str            # địa chỉ chuỗi
    syscall

    # Close file
    li   $v0, 16                        # sys_close (đóng file)
    move $a0, $s0
    syscall

size_mismatch_exit:
    li   $v0, 10                        # sys_exit
    syscall