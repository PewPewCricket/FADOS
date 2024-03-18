bits 16

%define ENDL 0x0D, 0x0A

mov si, find
call print
cli 
hlt

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

find: db 'Hello Stage 2!', ENDL, 0