org 0x7C00                              ; tell compiler where we are located in memory
bits 16                                 ; tell compiler that we are in 16 bit mode

%define ENDL 0x0D, 0x0A

; FAT12 header
jmp short start                         ; jump past FAT12 header and to actual code
nop                                     ; no operation

BPB_OEM_ID: db 'FADOS0.0'               ; OEM Identifier
BPB_BPS:    dw 512                      ; Bytes per Sector
BPB_SPC:    db 1                        ; Sectors per Cluster
BPB_RS:     dw 1                        ; Reserved Sectors
BPB_FC:     db 2                        ; Number of FATs on the drive
BPB_RDE:    dw 0E0h                     ; Root Dir Entry Count
BPB_TSC:    dw 2880                     ; Total Sector Count: 2880 * 512 = 1.44MB
BPB_MDT:    db 0F0h                     ; Media Descriptor Type: F0 = 3.5" floppy disk
BPB_SPF:    dw 9                        ; Sectors Per FAT
BPB_SPT:    dw 18                       ; Sectors Per Track
BPB_HC:     dw 2                        ; Head Count
BPB_HS:     dd 0                        ; Hidden Sectors
BPB_LSC:    dd 0                        ; Large Sector Count
EBR_DN:     db 0                        ; Drive Number: 0x00 floppy, 0x80 HDD, almost never used
            db 0                        ; Windows NT Flags: not used / reserved
EBR_SIG:    db 29h                      ; Boot Signature: this tells if the EBR data is present
EBR_VID:    db 12h, 34h, 56h, 78h       ; Volume ID: Drive Serial Number, almost never used
EBR_VL:     db 'FADOS0.0dev'            ; Volume Label: Name of the Drive, it can be whatever
EBR_SID:    db 'FAT12   '               ; System Identifier: FAT type

; Code section                          
start:                                  
    ; setup data segments               
    mov ax, 0                           ; can't set ds/es directly
    mov ds, ax                          ; set data segment to 0
    mov es, ax                          ; set extra segment to 0

    ; setup stack               
    mov ss, ax                          ; set stack segment to 0
    mov sp, 0x7C00                      ; stack grows downwards from where it is loaded into memory
    
    ; ensure we are loaded into memory in the right location
    push es
    push word .after
    retf

.after:                                 ; Get disk info and write it to FAT12 header
    mov [EBR_DN], dl                    ; BIOS should set DL to drive number

    ; show OEM_ID
    mov si, [BPB_OEM_ID]                ; move OEM Identifier into si
    call print                          ; print OEM ID
    
    ; show loading message
    mov si, msg_loading                 ; move loading message into si
    call print                          ; print message

    ; read drive parameters instead of relying on data on formatted disk
    push es                             ; save extra segment pointer to stack
    mov ah, 08h                         ; move 08 hex into ah
    int 13h                             ; call interupt 13 hex
    jc floppy_error                     ; if carry flag is set, jump to floppy read error handler
    pop es                              ; restore extra segment pointer from stack

    and cl, 0x3F                        ; remove top 2 bits
    xor ch, ch                          ; set ch to 0
    mov [BPB_SPT], cx                   ; sector count

    inc dh                              ; add 1 to dh
    mov [BPB_HC], dh                    ; head count

    ; compute LBA of root directory = reserved + fats * sectors_per_fat
    ; note: this section can be hardcoded
    mov ax, [BPB_SPF]                   ; move Sectors Per FAT into ax
    mov bl, [BPB_FC]                    ; move FAT Count into bl
    xor bh, bh                          ; set bh to 0
    mul bx                              ; ax = (fats * sectors_per_fat)
    add ax, [BPB_RS]                    ; ax = LBA of root directory
    push ax                             ; save ax to stack

    ; compute size of root directory = (32 * number_of_entries) / bytes_per_sector
    mov ax, [BPB_RDE]                   ; move Root Dir Entries into ax
    shl ax, 5                           ; ax *= 32
    xor dx, dx                          ; dx = 0
    div word [BPB_BPS]                  ; number of sectors we need to read

    test dx, dx                         ; if dx != 0, add 1
    jz .root_dir_after                  ;
    inc ax                              ; division remainder != 0, add 1
                                        ; this means we have a sector only partially filled with entries
.root_dir_after:

    ; read root directory
    mov cl, al                          ; cl = number of sectors to read = size of root directory
    pop ax                              ; ax = LBA of root directory
    mov dl, [EBR_DN]                    ; dl = drive number (we saved it previously)
    mov bx, buffer                      ; es:bx = buffer
    call disk_read                      ; read from disk

    ; search for stage 2
    xor bx, bx                          ; set bx to 0
    mov di, buffer                      ; move buffer into di

.search_stage2:
    mov si, stage2_bin                  ; move stage2 filename into si
    mov cx, 11                          ; compare up to 11 characters
    push di                             ; save di to stack
    repe cmpsb                          ; repeat while equal; compare ds:si with es:di
    pop di                              ; restore di from stack
    je .found_stage2                    ; jump to .found_stage2 if equal

    add di, 32                          ; add 32 to di
    inc bx                              ; add 1 to bx
    cmp bx, [BPB_RDE]                   ; compare Root Dir Entries to bx
    jl .search_stage2                   ; loop this code block if previous operation returns less than

    ; stage 2 not found
    jmp stage2_not_found_error          ; jump to floppy error handler

.found_stage2:

    ; di should have the address to the entry
    mov ax, [di + 26]                   ; first logical cluster field (offset 26)
    mov [stage2_cluster], ax            ; move ax into stage2 cluster

    ; load FAT from disk into memory
    mov ax, [BPB_RS]                    ; move Reserved Sectors into ax
    mov bx, buffer                      ; move buffer into bx
    mov cl, [BPB_SPF]                   ; move Sectors Per FAT into cl
    mov dl, [EBR_DN]                    ; move Drive Number into dl
    call disk_read                      ; read from disk

    ; read stage 2 and process FAT chain
    mov bx, STAGE2_LOAD_SEGMENT         ; move stage2 segment into bx
    mov es, bx                          ; move bx to extra segment pointer
    mov bx, STAGE2_LOAD_OFFSET          ; move stage2 offset into bx

.load_stage2_loop:
    
    ; Read next cluster
    mov ax, [stage2_cluster]            ; move stage2_cluster into ax
    
    ; not nice :( hardcoded value
    add ax, 31                          ; first cluster = (stage2_cluster - 2) * sectors_per_cluster + start_sector
                                        ; start sector = reserved + fats + root directory size = 1 + 18 + 134 = 33
    mov cl, 1                           ; move 1 into cl
    mov dl, [EBR_DN]                    ; move the drive number into dl
    call disk_read                      ; read from the disk

    add bx, [BPB_BPS]                   ; move Bytes Per Sector into bx

    ; compute location of next cluster
    mov ax, [stage2_cluster]            ; move stage2_cluster into ax
    mov cx, 3                           ; move 3 into cx
    mul cx                              ; multiply cx by ax
    mov cx, 2                           ; move 2 into cx
    div cx                              ; ax = index of entry in FAT, dx = cluster mod 2

    mov si, buffer                      ; move buffer into si
    add si, ax                          ; add ax to si
    mov ax, [ds:si]                     ; read entry from FAT table at index ax

    or dx, dx                           ; check if ax is zero
    jz .even                            ; if ax is zero jump to .even

.odd:
    shr ax, 4                           ; shift ax to the right by 4 bits
    jmp .next_cluster_after             ; jump to .next_cluster_after

.even:
    and ax, 0x0FFF                      ; move 0x0FFF into ax

.next_cluster_after:
    cmp ax, 0x0FF8                      ; subtract ax from 0x0FF8: end of chain
    jae .read_finish                    ; jump is result was above or equal

    mov [stage2_cluster], ax            ; move the cluster stage2 is located in into ax
    jmp .load_stage2_loop               ; jump to the stage 2 loading loop

.read_finish:
    
    ; jump to stage 2
    mov dl, [EBR_DN]                    ; move boot drive number into dl

    mov ax, STAGE2_LOAD_SEGMENT         ; move the stage 2 location into ax: set segment registers
    mov ds, ax                          ; move data segment to the stage 2 location
    mov es, ax                          ; move extra segment to the stage 2 location

    ; jump to the 2nd stage bootloader
    jmp STAGE2_LOAD_SEGMENT:STAGE2_LOAD_OFFSET

    jmp wait_key_and_reboot             ; should never happen, here just incase

    cli                                 ; disable interrupts, this way CPU can't get out of halt state
    hlt                                 ; halt processor

; Error handlers

floppy_error:
    mov si, msg_read_fail               ; move string to print into si
    call print                          ; print error
    jmp wait_key_and_reboot             ; jump to wait_key_and_reboot

stage2_not_found_error:
    mov si, msg_stage2_err              ; move string to print into si
    call print                          ; print error
    jmp wait_key_and_reboot             ; jump to wait_key_and_reboot

wait_key_and_reboot:
    mov ah, 0                           ; move 0 into ah
    int 16h                             ; wait for keypress
    jmp 0FFFFh:0                        ; jump to beginning of BIOS, should reboot

.halt:
    cli                                 ; disable interrupts, this way CPU can't get out of halt state
    hlt                                 ; halt processer 

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

; convert an lba address to a chs address
; ax = LBA address
; returns:
; cx = [bits 0-5]: sector number
; ch = [bits 6-15]: cylinder
; dh = head

lba_to_chs:

    push ax                             ; save ax to stack
    push dx                             ; save ax to stack

    xor dx, dx                          ; dx = 0
    div word [BPB_SPT]                  ; ax = LBA / SectorsPerTrack
                                        ; dx = LBA % SectorsPerTrack

    inc dx                              ; dx = (LBA % SectorsPerTrack + 1) = sector
    mov cx, dx                          ; cx = sector

    xor dx, dx                          ; dx = 0
    div word [BPB_HC]                   ; ax = (LBA / SectorsPerTrack) / Heads = cylinder
                                        ; dx = (LBA / SectorsPerTrack) % Heads = head
    mov dh, dl                          ; dh = head
    mov ch, al                          ; ch = cylinder (lower 8 bits)
    shl ah, 6
    or cl, ah                           ; put upper 2 bits of cylinder in CL

    pop ax                              ; restore ax from stack
    mov dl, al                          ; restore dl from stack
    pop ax                              ; restore ax from stack
    ret                                 ; return from function

; read from disk
; ax = LBA address
; cl = number of sectors to read (up to 128)
; dl = drive number
; es:bx = memory address where to store read data

disk_read:

    push ax                             ; save ax to stack
    push bx                             ; save bx to stack
    push cx                             ; save cx to stack
    push dx                             ; save dx to stack
    push di                             ; save di to stack

    push cx                             ; temporarily save CL (number of sectors to read)
    call lba_to_chs                     ; compute CHS address
    pop ax                              ; al = number of sectors to read
    
    mov ah, 02h                         ; move 02 in hex into ah
    mov di, 5                           ; retry count = 5

.retry:
    pusha                               ; save all registers, we don't know what bios modifies
    stc                                 ; set carry flag, some BIOS chips don't set it
    int 13h                             ; call interupt 13h: carry flag cleared = success
    jnc .done                           ; jump to .done if carry not set

    ; read failed
    popa                                ; restore all general purpose registers from stack
    call disk_reset                     ; reset disk controller

    dec di                              ; subtract 1 from di
    test di, di                         ; set zero flag if di and di AND to 0
    jnz .retry                          ; if result is not zero then retry

.fail:
    jmp floppy_error                    ; jump to error handler if all attempts failed

.done:
    popa                                ; restore all general purpose registers from stack

    pop di                              ; restore di regitser from stack
    pop dx                              ; restore dx register from stack
    pop cx                              ; restore cx register from stack
    pop bx                              ; restore bx register from stack
    pop ax                              ; restore ax register from stack
    ret                                 ; return from function

; reset disk controller
; ah = drive number

disk_reset:
    pusha                               ; push all values in registers to stack
    mov ah, 0                           ; move 0 into ah
    stc                                 ; set carry flag
    int 13h                             ; call interupt 13 in hex
    jc floppy_error                     ; jump if carry is set
    popa                                ; pop all values from stack
    ret                                 ; return from function

; data section

msg_loading:            db 'LOADING', ENDL, 0
msg_read_fail:          db 'DISK READ FAIL', ENDL, 0
msg_stage2_err:         db 'STAGE2.BIN NOT FOUND', ENDL, 0
stage2_bin:             db 'STAGE2  BIN', ENDL, 0
stage2_cluster:         dw 0
STAGE2_LOAD_SEGMENT     equ 0x2000
STAGE2_LOAD_OFFSET      equ 0

times 510-($-$$) db 0                   ; fill remaning space with 0s
dw 0AA55h                               ; last 2 bytes of boot sector

buffer:                                 ; buffer space