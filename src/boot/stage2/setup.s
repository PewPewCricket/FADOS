bits 16

%define ENDL 0x0D, 0x0A

; data

a20_ok:     db 'ENABLED A20'

; code

call enable_a20
cli
hlt

; A20 enable
test_a20:
    pusha

    mov ax, [0x7dfe]

    push bx
    mov bx, 0xffff
    mov es, bx
    pop bx

    mov bx, 0x7e0e

    mov dx, [es:bx]

    cmp ax, dx
    je .cont

    popa
    mov ax, 1
    ret

    .cont:
        mov ax, [0x7dff]

        push bx
        mov bx, 0xffff
        mov es, bx
        pop bx

        mov bx, 0x7e0f
        mov dx, [es:bx]

        cmp ax, dx
        je .exit

        popa
        mov ax, 1
        ret

    .exit:
        popa
        xor ax, ax
        ret

enable_a20:
    pusha

    ;BIOS
    mov ax, 0x2401 
    int 0x15

    call test_a20
    cmp ax, 1
    je .done

    ;Keyboard
    sti

    call wait_c
    mov al, 0xad
    out 0x64, al

    call wait_c
    mov al, 0xd0
    out 0x64, al

    call wait_d 
    in al, 0x60
    push ax

    call wait_d
    mov al, 0xd1
    out 0x64, al

    call wait_c
    pop ax
    or al, 2
    out 0x60, al

    call wait_c
    mov al, 0xae
    out 0x64, al

    call wait_c

    sti

    call test_a20
    cmp ax, 1
    je .done

    ;FastA20
    in al, 0x92
    or al, 2
    out 0x92, al

    call test_a20
    cmp al, 1
    je .done

    jmp $

    .done:
        popa
        mov si, a20_ok
        call print
        ret

wait_c:
    in al, 0x64
    test al, 2

    jnz wait_c
    ret

wait_d:
    in al, 0x64
    test al, 1

    jz wait_d
    ret

; print text to screen
; ds:si = pointer to string to print

print:
    push si                             ; save si to stack
    push ax                             ; save ax to stack
    push bx                             ; save bx to stack

.loop:
    lodsb                               ; loads next character in al
    or al, al                           ; verify if next character is null
    jz .done                            ; if next character is null then jump to .done

    mov ah, 0x0E                        ; call bios interrupt
    mov bh, 0                           ; set page number to 0
    int 0x10                            ; call interupt 0x10

    jmp .loop                           ; loop printing until all characters have been printed

.done:
    pop bx                              ; restore bx from stack
    pop ax                              ; restore ax from stack
    pop si                              ; restore si from stack
    ret                                 ; return from function
