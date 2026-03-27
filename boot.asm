[BITS 16]
[ORG 0x7C00]

; ============================================================
;  TinyOS v0.0.0 — a mini operating system with shell & games
;  Features: shell, help, clear, reboot, shutdown, echo, color,
;            prompt, calculator, memory viewer, sysinfo, snake
; ============================================================

%define VIDEO_MEM     0xB800

start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    sti

    ; Set video mode 3 (80x25 color text)
    mov ax, 0x0003
    int 0x10

    call clear_screen
    call draw_banner
    mov si, msg_type_help
    call print_string

shell:
    ; Print prompt
    mov ah, 0x0E
    mov al, 13
    int 0x10
    mov al, 10
    int 0x10

    ; Use custom prompt if set, otherwise default colored prompt
    cmp byte [custom_prompt], 0
    je .default_prompt
    mov si, custom_prompt
    call print_string
    jmp .prompt_done
.default_prompt:
    call print_colored_prompt
.prompt_done:

    ; Save cursor position (start of input area)
    mov ah, 0x03
    xor bh, bh
    int 0x10
    mov [input_row], dh
    mov [input_col], dl

    ; Read command into buffer
    xor cx, cx              ; CL = character count
    mov byte [cursor_pos], 0
    mov byte [hist_browse], 0

.read_key:
    xor ah, ah
    int 0x16

    cmp al, 13              ; Enter
    je .execute
    cmp al, 8               ; Backspace
    je .backspace
    cmp ah, 0x48            ; Up arrow
    je .hist_up
    cmp ah, 0x50            ; Down arrow
    je .hist_down
    cmp ah, 0x4B            ; Left arrow
    je .move_left
    cmp ah, 0x4D            ; Right arrow
    je .move_right

    ; Ignore non-printable keys
    cmp al, 32
    jb .read_key

    cmp cl, 63              ; max command length
    jge .read_key

    ; --- Insert character at cursor_pos ---
    push ax
    xor bh, bh
    mov bl, cl              ; BX = current length
.ins_shift:
    cmp bl, [cursor_pos]
    je .ins_place
    mov al, [cmd_buffer + bx - 1]
    mov [cmd_buffer + bx], al
    dec bl
    jmp .ins_shift
.ins_place:
    pop ax
    mov [cmd_buffer + bx], al
    inc cl
    inc byte [cursor_pos]
    call .redraw_line
    jmp .read_key

.backspace:
    cmp byte [cursor_pos], 0
    jz .read_key
    ; Shift buffer[cursor_pos..length-1] left by 1
    xor bh, bh
    mov bl, [cursor_pos]
    dec bl
.bs_shift:
    mov al, cl
    dec al
    cmp bl, al
    jge .bs_done
    mov al, [cmd_buffer + bx + 1]
    mov [cmd_buffer + bx], al
    inc bl
    jmp .bs_shift
.bs_done:
    dec cl
    dec byte [cursor_pos]
    call .redraw_line
    jmp .read_key

.move_left:
    cmp byte [cursor_pos], 0
    je .read_key
    dec byte [cursor_pos]
    mov ah, 0x02
    xor bh, bh
    mov dh, [input_row]
    mov dl, [input_col]
    add dl, [cursor_pos]
    int 0x10
    jmp .read_key

.move_right:
    mov al, [cursor_pos]
    cmp al, cl
    jge .read_key
    inc byte [cursor_pos]
    mov ah, 0x02
    xor bh, bh
    mov dh, [input_row]
    mov dl, [input_col]
    add dl, [cursor_pos]
    int 0x10
    jmp .read_key

.hist_up:
    mov al, [hist_browse]
    cmp al, [hist_count]
    jge .read_key            ; already at oldest
    inc al
    mov [hist_browse], al
    call .load_history
    jmp .read_key

.hist_down:
    cmp byte [hist_browse], 0
    je .read_key             ; already at newest
    dec byte [hist_browse]
    cmp byte [hist_browse], 0
    je .hist_clear
    call .load_history
    jmp .read_key
.hist_clear:
    call .clear_input
    xor cx, cx
    mov byte [cursor_pos], 0
    mov ah, 0x02
    xor bh, bh
    mov dh, [input_row]
    mov dl, [input_col]
    int 0x10
    jmp .read_key

; Load history entry into cmd_buffer, redraw
.load_history:
    call .clear_input
    call .get_hist_entry     ; SI = history entry
    mov di, cmd_buffer
    xor cl, cl
.lh_copy:
    lodsb
    or al, al
    jz .lh_done
    stosb
    inc cl
    jmp .lh_copy
.lh_done:
    mov [cursor_pos], cl     ; cursor at end
    call .redraw_line
    ret

; Clear current input from screen (CL chars)
.clear_input:
    mov ah, 0x02
    xor bh, bh
    mov dh, [input_row]
    mov dl, [input_col]
    int 0x10
    xor bx, bx
.ci_loop:
    cmp bl, cl
    jge .ci_done
    mov ah, 0x0E
    mov al, ' '
    int 0x10
    inc bl
    jmp .ci_loop
.ci_done:
    ret

; Redraw input line and position cursor
.redraw_line:
    mov ah, 0x02
    xor bh, bh
    mov dh, [input_row]
    mov dl, [input_col]
    int 0x10
    xor bx, bx
.rl_loop:
    cmp bl, cl
    jge .rl_trail
    mov al, [cmd_buffer + bx]
    mov ah, 0x0E
    int 0x10
    inc bl
    jmp .rl_loop
.rl_trail:
    ; Clear one trailing char (handles backspace/delete)
    mov ah, 0x0E
    mov al, ' '
    int 0x10
    ; Position cursor at cursor_pos
    mov ah, 0x02
    xor bh, bh
    mov dh, [input_row]
    mov dl, [input_col]
    add dl, [cursor_pos]
    int 0x10
    ret

; Get history entry for current hist_browse -> SI
; hist_browse=1 is most recent, 2 is one before, etc.
.get_hist_entry:
    mov al, [hist_wpos]
    sub al, [hist_browse]
    jns .hist_no_wrap
    add al, 8
.hist_no_wrap:
    ; AL = slot index, multiply by 64
    xor ah, ah
    shl ax, 6               ; *64
    add ax, history
    mov si, ax
    ret

.execute:
    ; Null-terminate at length
    xor bh, bh
    mov bl, cl
    mov byte [cmd_buffer + bx], 0
    mov byte [hist_browse], 0

    ; Don't save empty commands
    cmp byte [cmd_buffer], 0
    je .skip_save

    ; Save command to history
    push si
    push di
    mov al, [hist_wpos]
    xor ah, ah
    shl ax, 6               ; *64
    add ax, history
    mov di, ax
    mov si, cmd_buffer
.save_cmd:
    lodsb
    stosb
    or al, al
    jnz .save_cmd
    pop di
    pop si

    ; Advance write position
    inc byte [hist_wpos]
    and byte [hist_wpos], 7  ; mod 8
    cmp byte [hist_count], 8
    jge .skip_save
    inc byte [hist_count]
.skip_save:
    ; Skip leading spaces
    mov si, cmd_buffer
.skip_spaces:
    lodsb
    cmp al, ' '
    je .skip_spaces
    dec si

    ; Empty command? Go back to prompt without blank line
    cmp byte [si], 0
    je shell

    ; Print newline before command output
    mov al, 13
    mov ah, 0x0E
    int 0x10
    mov al, 10
    int 0x10

    ; Match commands
    mov di, cmd_help
    call str_starts_with
    jc do_help

    mov di, cmd_clear
    call str_starts_with
    jc do_clear

    mov di, cmd_reboot
    call str_starts_with
    jc do_reboot

    mov di, cmd_shutdown
    call str_starts_with
    jc do_shutdown

    mov di, cmd_echo
    call str_starts_with
    jc do_echo

    mov di, cmd_color
    call str_starts_with
    jc do_color

    mov di, cmd_calc
    call str_starts_with
    jc do_calc

    mov di, cmd_mem
    call str_starts_with
    jc do_mem

    mov di, cmd_snake
    call str_starts_with
    jc do_snake

    mov di, cmd_sysinfo
    call str_starts_with
    jc do_sysinfo

    mov di, cmd_prompt_sp
    call str_starts_with
    jc do_prompt_set

    mov di, cmd_prompt
    call str_starts_with
    jc do_prompt_reset

    ; Unknown command
    mov si, msg_unknown
    call print_string
    jmp shell

; ============================================================
;  COMMANDS
; ============================================================

do_help:
    mov si, msg_help
    call print_string
    jmp shell

do_clear:
    call clear_screen
    jmp shell

do_reboot:
    mov si, msg_rebooting
    call print_string
    ; Wait a moment
    mov cx, 0x000F
    mov dx, 0x4240
    mov ah, 0x86
    int 0x15
    jmp 0xFFFF:0x0000

do_shutdown:
    mov si, msg_shutdown
    call print_string
    ; Wait a moment
    mov cx, 0x000F
    mov dx, 0x4240
    mov ah, 0x86
    int 0x15
    ; APM shutdown (works in QEMU and most BIOS)
    mov ax, 0x5301          ; APM connect real mode
    xor bx, bx
    int 0x15
    mov ax, 0x530E          ; APM set version 1.2
    xor bx, bx
    mov cx, 0x0102
    int 0x15
    mov ax, 0x5307          ; APM set power state
    mov bx, 0x0001          ; all devices
    mov cx, 0x0003          ; off
    int 0x15
    ; If APM failed, halt
    cli
    hlt

do_echo:
    ; SI already points past "echo " from str_starts_with
.echo_skip:
    cmp byte [si], ' '
    jne .echo_print
    inc si
    jmp .echo_skip
.echo_print:
    call print_string
    jmp shell

do_color:
.color_skip:
    cmp byte [si], ' '
    jne .color_parse
    inc si
    jmp .color_skip
.color_parse:
    call parse_decimal
    and al, 0x0F
    mov [current_color], al
    mov si, msg_color_set
    call print_string
    jmp shell

do_prompt_set:
    ; Copy argument to custom_prompt
    mov di, custom_prompt
.prompt_copy:
    lodsb
    stosb
    or al, al
    jnz .prompt_copy
    mov si, msg_prompt_set
    call print_string
    jmp shell

do_prompt_reset:
    mov byte [custom_prompt], 0
    mov si, msg_prompt_reset
    call print_string
    jmp shell

do_sysinfo:
    ; Get conventional memory size
    int 0x12                ; returns KB in AX
    push ax

    mov si, msg_sysinfo1
    call print_string

    pop ax
    call print_decimal
    mov si, msg_kb
    call print_string

    mov si, msg_sysinfo2
    call print_string

    jmp shell

; ============================================================
;  CALCULATOR — supports: N + N, N - N, N * N, N / N
; ============================================================

do_calc:
.calc_skip:
    cmp byte [si], ' '
    jne .calc_parse
    inc si
    jmp .calc_skip
.calc_parse:
    ; Parse first number
    call parse_decimal
    push ax                  ; save first operand (parse_decimal clobbers BX)

    ; Skip spaces to operator
.find_op:
    lodsb
    cmp al, ' '
    je .find_op
    mov cl, al              ; operator in CL

    ; Skip spaces to second number
.find_num2:
    cmp byte [si], ' '
    jne .parse_num2
    inc si
    jmp .find_num2
.parse_num2:
    push cx                  ; save operator (parse_decimal clobbers CX)
    call parse_decimal
    mov dx, ax               ; second operand in DX
    pop cx                   ; restore operator in CL
    pop bx                   ; restore first operand into BX

    ; Perform operation
    cmp cl, '+'
    je .calc_add
    cmp cl, '-'
    je .calc_sub
    cmp cl, '*'
    je .calc_mul
    cmp cl, '/'
    je .calc_div

    mov si, msg_calc_err
    call print_string
    jmp shell

.calc_add:
    add bx, dx
    jmp .calc_result
.calc_sub:
    sub bx, dx
    jmp .calc_result
.calc_mul:
    mov ax, bx
    imul dx
    mov bx, ax
    jmp .calc_result
.calc_div:
    or dx, dx
    jz .calc_div_zero
    mov ax, bx
    mov cx, dx
    xor dx, dx
    div cx
    mov bx, ax
    jmp .calc_result

.calc_div_zero:
    mov si, msg_div_zero
    call print_string
    jmp shell

.calc_result:
    push bx                  ; save result (print_string clobbers BX)
    mov si, msg_equals
    call print_string
    pop ax                   ; restore result into AX
    call print_signed_decimal
    jmp shell

; ============================================================
;  MEMORY VIEWER — mem ADDR (hex), shows 64 bytes
; ============================================================

do_mem:
.mem_skip:
    cmp byte [si], ' '
    jne .mem_parse
    inc si
    jmp .mem_skip
.mem_parse:
    call parse_hex          ; result in AX
    mov bx, ax              ; address in BX

    ; Display 4 rows of 16 bytes
    mov cx, 4
.mem_row:
    push cx

    ; Print address
    mov ax, bx
    call print_hex_word
    mov ah, 0x0E
    mov al, ':'
    int 0x10
    mov al, ' '
    int 0x10

    ; Print 16 hex bytes
    push bx
    mov cx, 16
.mem_byte:
    mov al, [bx]
    call print_hex_byte
    mov ah, 0x0E
    mov al, ' '
    int 0x10
    inc bx
    loop .mem_byte
    pop bx

    ; Print ASCII
    mov ah, 0x0E
    mov al, '|'
    int 0x10
    mov cx, 16
.mem_ascii:
    mov al, [bx]
    cmp al, 32
    jb .mem_dot
    cmp al, 126
    ja .mem_dot
    jmp .mem_print_char
.mem_dot:
    mov al, '.'
.mem_print_char:
    mov ah, 0x0E
    int 0x10
    inc bx
    loop .mem_ascii

    mov ah, 0x0E
    mov al, '|'
    int 0x10
    mov al, 13
    int 0x10
    mov al, 10
    int 0x10

    pop cx
    loop .mem_row

    jmp shell

; ============================================================
;  SNAKE GAME
; ============================================================

do_snake:
    call clear_screen

    ; Init snake
    mov word [snake_x], 40
    mov word [snake_y], 12
    mov word [snake_dir], 0     ; 0=right,1=down,2=left,3=up
    mov word [snake_len], 3
    mov word [snake_score], 0
    mov byte [snake_alive], 1

    ; Clear snake body buffer
    mov di, snake_body
    mov cx, 256
    xor ax, ax
    rep stosw

    ; Set initial body
    mov word [snake_body], 40
    mov word [snake_body+2], 12
    mov word [snake_body+4], 39
    mov word [snake_body+6], 12
    mov word [snake_body+8], 38
    mov word [snake_body+10], 12

    ; Place first food
    call snake_place_food

    ; Draw border
    call snake_draw_border

.snake_loop:
    cmp byte [snake_alive], 0
    je .snake_dead

    ; Draw snake and food
    call snake_draw

    ; Delay
    mov cx, 0x0001
    mov dx, 0x8000
    mov ah, 0x86
    int 0x15

    ; Check keyboard (non-blocking)
    mov ah, 0x01
    int 0x16
    jz .snake_no_key

    ; Read the key
    xor ah, ah
    int 0x16

    cmp ah, 0x48            ; up
    je .snake_up
    cmp ah, 0x50            ; down
    je .snake_down
    cmp ah, 0x4B            ; left
    je .snake_left
    cmp ah, 0x4D            ; right
    je .snake_right
    cmp al, 'q'
    je .snake_quit
    cmp al, 27              ; ESC
    je .snake_quit
    jmp .snake_no_key

.snake_up:
    cmp word [snake_dir], 1
    je .snake_no_key
    mov word [snake_dir], 3
    jmp .snake_no_key
.snake_down:
    cmp word [snake_dir], 3
    je .snake_no_key
    mov word [snake_dir], 1
    jmp .snake_no_key
.snake_left:
    cmp word [snake_dir], 0
    je .snake_no_key
    mov word [snake_dir], 2
    jmp .snake_no_key
.snake_right:
    cmp word [snake_dir], 2
    je .snake_no_key
    mov word [snake_dir], 0
    jmp .snake_no_key

.snake_no_key:
    ; Move snake — shift body
    mov cx, [snake_len]
    dec cx
    shl cx, 2               ; *4 bytes per segment (x,y words)

.shift_body:
    cmp cx, 0
    jle .shift_done
    mov bx, cx
    mov ax, [snake_body + bx - 4]
    mov [snake_body + bx], ax
    mov ax, [snake_body + bx - 2]
    mov [snake_body + bx + 2], ax
    sub cx, 4
    jmp .shift_body

.shift_done:
    ; Erase tail (old last segment)
    mov cx, [snake_len]
    shl cx, 2
    mov bx, cx
    mov ax, [snake_body + bx]     ; tail x (now old)
    mov bx, [snake_body + bx + 2] ; tail y
    call snake_put_space

    ; Move head
    mov ax, [snake_x]
    mov bx, [snake_y]

    cmp word [snake_dir], 0
    je .move_right
    cmp word [snake_dir], 1
    je .move_down
    cmp word [snake_dir], 2
    je .move_left
    ; else up
    dec bx
    jmp .move_done
.move_right:
    inc ax
    jmp .move_done
.move_down:
    inc bx
    jmp .move_done
.move_left:
    dec ax

.move_done:
    mov [snake_x], ax
    mov [snake_y], bx
    mov [snake_body], ax
    mov [snake_body+2], bx

    ; Check wall collision
    cmp ax, 1
    jl .snake_die
    cmp ax, 78
    jg .snake_die
    cmp bx, 1
    jl .snake_die
    cmp bx, 23
    jg .snake_die

    ; Check food collision
    cmp ax, [food_x]
    jne .snake_no_food
    cmp bx, [food_y]
    jne .snake_no_food

    ; Eat food
    inc word [snake_len]
    inc word [snake_score]
    call snake_place_food
    jmp .snake_loop

.snake_no_food:
    jmp .snake_loop

.snake_die:
    mov byte [snake_alive], 0
    jmp .snake_loop

.snake_dead:
    call clear_screen

    mov si, msg_gameover
    call print_string

    mov si, msg_score
    call print_string
    mov ax, [snake_score]
    call print_decimal

    mov si, msg_press_key
    call print_string

    xor ah, ah
    int 0x16

.snake_quit:
    call clear_screen
    jmp shell

; --- Snake helpers ---

snake_draw_border:
    push es
    mov ax, VIDEO_MEM
    mov es, ax

    ; Top & bottom border
    xor cx, cx
.border_top:
    mov di, cx
    shl di, 1
    mov word [es:di], 0x0F23         ; '#' white on black
    mov di, 24 * 160
    add di, cx
    add di, cx
    mov word [es:di], 0x0F23
    inc cx
    cmp cx, 80
    jl .border_top

    ; Left & right border
    mov cx, 1
.border_side:
    mov ax, cx
    mov bx, 160
    mul bx
    mov di, ax
    mov word [es:di], 0x0F23
    add di, 79 * 2
    mov word [es:di], 0x0F23
    inc cx
    cmp cx, 24
    jl .border_side

    ; Score label at top
    mov di, 2
    mov si, msg_snake_score
.score_label:
    lodsb
    or al, al
    jz .score_done
    mov [es:di], al
    mov byte [es:di+1], 0x0E
    add di, 2
    jmp .score_label
.score_done:
    pop es
    ret

snake_draw:
    push es
    mov ax, VIDEO_MEM
    mov es, ax

    ; Draw food
    mov ax, [food_y]
    mov bx, 160
    mul bx
    mov di, ax
    mov ax, [food_x]
    shl ax, 1
    add di, ax
    mov word [es:di], 0x0C04        ; diamond, red

    ; Draw snake body
    mov cx, [snake_len]
    xor si, si
.draw_seg:
    push cx
    mov ax, [snake_body + si + 2]   ; y
    mov bx, 160
    mul bx
    mov di, ax
    mov ax, [snake_body + si]       ; x
    shl ax, 1
    add di, ax

    cmp si, 0
    jne .draw_body
    mov word [es:di], 0x0A40        ; '@' green head
    jmp .draw_next
.draw_body:
    mov word [es:di], 0x020F        ; 'O' green body (actually block char)
.draw_next:
    add si, 4
    pop cx
    loop .draw_seg

    ; Update score display
    mov di, 16
    mov ax, [snake_score]
    ; Simple 1-3 digit score
    call snake_print_score_vga

    pop es
    ret

snake_put_space:
    ; AX=x, BX=y — clear that cell
    push es
    mov cx, VIDEO_MEM
    mov es, cx
    ; DI = y * 160 + x * 2
    xchg ax, bx         ; AX=y, BX=x
    mov cx, 160
    mul cx               ; AX = y*160
    mov di, ax
    shl bx, 1
    add di, bx
    mov word [es:di], 0x0F20
    pop es
    ret

snake_place_food:
    ; Simple pseudo-random placement
    push es
    mov ax, 0x0040
    mov es, ax
    mov ax, [es:0x006C]     ; BIOS tick counter
    pop es

    ; X = (ticks % 76) + 2
    xor dx, dx
    mov cx, 76
    div cx
    add dx, 2
    mov [food_x], dx

    ; Y from different bits
    push es
    mov ax, 0x0040
    mov es, ax
    mov ax, [es:0x006C]
    pop es
    shr ax, 8
    xor dx, dx
    mov cx, 21
    div cx
    add dx, 2
    mov [food_y], dx
    ret

snake_print_score_vga:
    ; Print AX as decimal at ES:DI (VGA)
    ; Caller must set ES to VIDEO_MEM
    mov bx, 10
    xor cx, cx
.svga_div:
    xor dx, dx
    div bx
    push dx
    inc cx
    or ax, ax
    jnz .svga_div
.svga_print:
    pop dx
    add dl, '0'
    mov [es:di], dl
    mov byte [es:di+1], 0x0E
    add di, 2
    loop .svga_print
    ret

; ============================================================
;  UTILITY FUNCTIONS
; ============================================================

; Compare string at SI with null-terminated string at DI
; Sets carry if match (SI advanced past the matched keyword)
str_starts_with:
    push si
    push di
.cmp_loop:
    mov al, [di]
    or al, al               ; end of keyword?
    jz .cmp_match
    mov ah, [si]
    cmp al, ah
    jne .cmp_fail
    inc si
    inc di
    jmp .cmp_loop
.cmp_fail:
    pop di
    pop si
    clc
    ret
.cmp_match:
    pop di
    add sp, 2               ; discard saved SI
    stc
    ret

clear_screen:
    ; Turn screen off (forces QEMU to fully redraw when turned back on)
    mov dx, 0x03C4
    mov al, 0x01
    out dx, al
    inc dx
    in al, dx
    or al, 0x20            ; screen off bit
    out dx, al

    ; Reset VGA display start address to 0
    mov dx, 0x03D4
    mov al, 0x0C
    out dx, al
    inc dx
    xor al, al
    out dx, al
    dec dx
    mov al, 0x0D
    out dx, al
    inc dx
    xor al, al
    out dx, al

    ; Clear entire VGA text buffer
    push es
    mov ax, VIDEO_MEM
    mov es, ax
    xor di, di
    mov cx, 16384
    mov ax, 0x0F20
    rep stosw
    pop es

    ; Reset cursor to top-left
    mov ah, 0x02
    xor bh, bh
    xor dx, dx
    int 0x10

    ; Turn screen back on
    mov dx, 0x03C4
    mov al, 0x01
    out dx, al
    inc dx
    in al, dx
    and al, 0xDF            ; clear screen off bit
    out dx, al
    ret

print_string:
    lodsb
    or al, al
    jz .ps_done
    cmp al, 13
    je .ps_ctrl
    cmp al, 10
    je .ps_ctrl
    ; Write char with color using AH=09, then advance cursor
    mov bl, [current_color]
    xor bh, bh
    mov cx, 1
    mov ah, 0x09
    int 0x10
    ; Advance cursor manually
    mov ah, 0x03
    xor bh, bh
    int 0x10
    inc dl
    cmp dl, 80
    jb .ps_setcur
    xor dl, dl
    inc dh
.ps_setcur:
    mov ah, 0x02
    int 0x10
    jmp print_string
.ps_ctrl:
    ; CR/LF via teletype (handles scrolling)
    mov ah, 0x0E
    int 0x10
    jmp print_string
.ps_done:
    ret

print_colored_prompt:
    ; Print "tiny" in green, "os" in cyan, "> " in white
    mov al, 't'
    mov bl, 0x0A            ; green
    call .print_color_char
    mov al, 'i'
    call .print_color_char
    mov al, 'n'
    call .print_color_char
    mov al, 'y'
    call .print_color_char
    mov bl, 0x0B            ; cyan
    mov al, 'o'
    call .print_color_char
    mov al, 's'
    call .print_color_char
    mov bl, 0x0F            ; white
    mov al, '>'
    call .print_color_char
    mov al, ' '
    call .print_color_char
    ret

.print_color_char:
    mov ah, 0x09
    xor bh, bh
    mov cx, 1
    int 0x10
    ; Advance cursor
    mov ah, 0x03
    int 0x10
    inc dl
    mov ah, 0x02
    int 0x10
    ret

draw_banner:
    mov si, banner1
    call print_string
    mov si, banner2
    call print_string
    mov si, banner3
    call print_string
    mov si, banner4
    call print_string
    mov si, banner5
    call print_string
    mov si, banner6
    call print_string
    ret

print_signed_decimal:
    ; Print AX as signed decimal
    test ax, 0x8000
    jz print_decimal         ; positive, just print normally
    ; Negative: print '-' then negate
    push ax
    mov ah, 0x0E
    mov al, '-'
    int 0x10
    pop ax
    neg ax                   ; make positive

print_decimal:
    ; Print AX as unsigned decimal
    xor cx, cx
    mov bx, 10
.pd_div:
    xor dx, dx
    div bx
    push dx
    inc cx
    or ax, ax
    jnz .pd_div
.pd_print:
    pop dx
    add dl, '0'
    mov ah, 0x0E
    mov al, dl
    int 0x10
    loop .pd_print
    ret

print_hex_word:
    ; Print AX as 4-digit hex
    push ax
    mov al, ah
    call print_hex_byte
    pop ax
    call print_hex_byte
    ret

print_hex_byte:
    ; Print AL as 2-digit hex
    push ax
    shr al, 4
    call .hex_nibble
    pop ax
    and al, 0x0F
    call .hex_nibble
    ret
.hex_nibble:
    cmp al, 10
    jb .hex_digit
    add al, 'A' - 10
    jmp .hex_out
.hex_digit:
    add al, '0'
.hex_out:
    mov ah, 0x0E
    int 0x10
    ret

parse_decimal:
    ; Parse decimal number from [SI], result in AX
    ; Advances SI past the number
    xor ax, ax
    xor cx, cx
.pdec_loop:
    mov cl, [si]
    cmp cl, '0'
    jb .pdec_done
    cmp cl, '9'
    ja .pdec_done
    sub cl, '0'
    mov bx, 10
    mul bx
    add ax, cx
    inc si
    jmp .pdec_loop
.pdec_done:
    ret

parse_hex:
    ; Parse hex number from [SI], result in AX
    ; Supports optional 0x prefix
    cmp byte [si], '0'
    jne .phex_go
    cmp byte [si+1], 'x'
    jne .phex_go
    add si, 2
.phex_go:
    xor ax, ax
.phex_loop:
    mov cl, [si]
    cmp cl, '0'
    jb .phex_done
    cmp cl, '9'
    jbe .phex_digit
    cmp cl, 'A'
    jb .phex_check_lower
    cmp cl, 'F'
    jbe .phex_upper
    jmp .phex_check_lower
.phex_digit:
    sub cl, '0'
    jmp .phex_add
.phex_upper:
    sub cl, 'A' - 10
    jmp .phex_add
.phex_check_lower:
    cmp cl, 'a'
    jb .phex_done
    cmp cl, 'f'
    ja .phex_done
    sub cl, 'a' - 10
.phex_add:
    shl ax, 4
    xor ch, ch
    add ax, cx
    inc si
    jmp .phex_loop
.phex_done:
    ret

; ============================================================
;  DATA
; ============================================================

banner1 db 13, 10
        db '  _______ _             ____   _____  ', 13, 10, 0
banner2 db ' |__   __(_)           / __ \ / ____| ', 13, 10, 0
banner3 db '    | |   _ _ __  _  | |  | | (___   ', 13, 10, 0
banner4 db '    | |  | | `_ \| | | |  | |\___ \  ', 13, 10, 0
banner5 db '    | |  | | | | | |_| |__| |____) | ', 13, 10, 0
banner6 db '    |_|  |_|_| |_|\__, \____/|_____/  v0.0.0', 13, 10
        db '                   __/ |', 13, 10
        db '                  |___/', 13, 10, 0

msg_type_help db 13, 10, '  Type "help" for available commands.', 13, 10, 0

msg_help db '  Available commands:', 13, 10
         db '  -------------------', 13, 10
         db '  help       Show this help message', 13, 10
         db '  clear      Clear the screen', 13, 10
         db '  echo TEXT  Print text to screen', 13, 10
         db '  color N    Set text color (0-15)', 13, 10
         db '  calc EXPR  Calculator (e.g. calc 7 + 3)', 13, 10
         db '  mem ADDR   View memory (e.g. mem 7C00)', 13, 10
         db '  sysinfo    Show system information', 13, 10
         db '  prompt TXT Set prompt (no arg = reset)', 13, 10
         db '  snake      Play Snake!', 13, 10
         db '  reboot     Reboot the computer', 13, 10
         db '  shutdown   Power off the computer', 13, 10, 0

msg_unknown   db '  Unknown command. Type "help" for commands.', 13, 10, 0
msg_rebooting db '  Rebooting...', 0
msg_shutdown  db '  Shutting down...', 0
msg_color_set   db '  Color updated.', 0
msg_prompt_set   db '  Prompt updated.', 0
msg_prompt_reset db '  Prompt reset to default.', 0
msg_equals    db '  = ', 0
msg_calc_err  db '  Error: use "calc N + N" (operators: + - * /)', 0
msg_div_zero  db '  Error: division by zero', 0
msg_gameover  db 13, 10, '    === GAME OVER ===', 13, 10, 0
msg_score     db '    Score: ', 0
msg_press_key db 13, 10, 13, 10, '    Press any key...', 0
msg_kb        db ' KB', 13, 10, 0

msg_sysinfo1  db '  System Information:', 13, 10
              db '  -------------------', 13, 10
              db '  OS:      TinyOS v0.0.0', 13, 10
              db '  Arch:    x86 (16-bit Real Mode)', 13, 10
              db '  Video:   VGA 80x25 color text', 13, 10
              db '  Memory:  ', 0

msg_sysinfo2  db '  Boot:    El Torito CD-ROM', 13, 10, 0

msg_snake_score db ' Score: ', 0

; Command strings (null-terminated)
cmd_help   db 'help', 0
cmd_clear  db 'clear', 0
cmd_reboot   db 'reboot', 0
cmd_shutdown db 'shutdown', 0
cmd_echo   db 'echo ', 0
cmd_color  db 'color ', 0
cmd_calc   db 'calc ', 0
cmd_mem    db 'mem ', 0
cmd_snake  db 'snake', 0
cmd_sysinfo   db 'sysinfo', 0
cmd_prompt_sp db 'prompt ', 0
cmd_prompt    db 'prompt', 0

; Variables
current_color db 0x0F

; Game variables
snake_x     dw 0
snake_y     dw 0
snake_dir   dw 0
snake_len   dw 0
snake_score dw 0
snake_alive db 0
food_x      dw 0
food_y      dw 0

; Buffers
cmd_buffer     times 64 db 0
custom_prompt  times 32 db 0       ; custom prompt string (empty = default)
history     times 512 db 0       ; 8 entries * 64 bytes
hist_count  db 0                 ; number of entries stored
hist_wpos   db 0                 ; next write slot (0-7)
hist_browse db 0                 ; current browse offset (0=none)
cursor_pos  db 0                 ; cursor position within input
input_row   db 0                 ; screen row of input start
input_col   db 0                 ; screen column of input start
snake_body  times 512 db 0       ; up to 128 segments (x,y pairs)

; Pad to multiple of 512 bytes (for CD boot)
times 8192 - ($ - $$) db 0
