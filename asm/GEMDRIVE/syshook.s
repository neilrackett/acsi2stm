; ACSI2STM Atari hard drive emulator
; Copyright (C) 2019-2025 by Jean-Matthieu Coulon
; Copyright (C) 2026 by Neil Rackett
; SPDX-License-Identifier: GPL-3.0-or-later

; This program is free software: you can redistribute it and/or modify
; it under the terms of the GNU General Public License as published by
; the Free Software Foundation, either version 3 of the License, or
; (at your option) any later version.

; This program is distributed in the hope that it will be useful,
; but WITHOUT ANY WARRANTY; without even the implied warranty of
; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
; GNU General Public License for more details.

; You should have received a copy of the GNU General Public License
; along with this program.  If not, see <https://www.gnu.org/licenses/>.

; Hooks TOS system calls into the STM32

savereg	macro
	; Save registers on stack
	; ... because some poorly written apps rely on scratch register being
	; preserved !
	movem.l	d1-d2/a0-a2,-(sp)
	endm

resreg	macro
	; Restore registers from stack
	movem.l	(sp)+,d1-d2/a0-a2
	endm

	; Stack offset introduced by savereg
spoff	equ	5*4

	; Size of the private stack, see syshook.bounce
syshook.stksize	equ	2048

	; Build variants. MSTE is the Mega STE switch (see mste.i), PRG is 1
	; in GEMDRIVE.PRG and 0 in the boot sector.
	; GEMDRIVE.PRG has room for everything and sorts it out when it starts.
	; The boot sector has either the Mega STE cache workaround, or what a
	; 68030 and TT-RAM need.
syshook.mstefix	equ	MSTE+PRG        ; Not 0: cache workaround built in
syshook.nott	equ	MSTE*(1-PRG)    ; Not 0: 68030 and TT-RAM code left out
syshook.diag	equ	DIAG*PRG        ; Not 0: diagnostic GEMDRIVE.PRG

syshook:
	; Initialize registers for hook subroutines
	; Input:
	;  d0.b: Command byte
	;  syshook.prmoff: Offset to a7 to find params (platform dependent)

	tst.b	flock.w                 ; Prevent reentrant calls
	bne.b	syshook.rts             ;

	savereg	                        ; Save registers

	bsr.w	syshook.setprm          ; Set a2 (DMA address) at the parameters

	IFNE	syshook.diag
	lea	syshook.diagop(pc),a0   ; Remember the GEMDOS opcode
	move.w	(a2),(a0)               ;
	btst	#5,4+spoff(sp)          ; Test supervisor mode again
	ENDC

	IFEQ	syshook.nott
	bne.b	syshook.bounce          ; Supervisor mode: use the private stack
	ENDC

	cmp.w	#$0020,(a2)             ; Don't hook Super because it breaks
	beq.b	syshook.forward         ; some programs such as ICDFMT.PRG

	cmpa.l	phystop.w,a2            ; DMA can't reach parameters above
	IFNE	syshook.nott
	bhs.b	syshook.forward         ; phystop: leave the call to TOS
	ELSE
	bhs.b	syshook.usrbnc          ; phystop (TT-RAM, Alt-RAM)
	ENDC

syshook.sendcmd:
	IFNE	syshook.diag
	bsr.w	syshook.msteoff         ; Turn the Mega STE cache off
	ELSE
	IFNE	syshook.mstefix
	bsr.b	syshook.msteoff         ; Turn the Mega STE cache off
	ENDC
	ENDC
	st	flock.w                 ; Lock floppy controller
	bsr.w	syshook.setdmaaddr      ; Set DMA address on chip

	move.w	#$00ff,(a0)             ; Send 255 blocks.
	move.w	#$0188,(a1)             ; Switch to command.
	and.w	#$00ff,d0               ; Filter command byte
	move.w	d0,(a0)                 ; Send command byte to the STM32
	move.w	#$0100,(a1)             ; Start DMA

syshook.reply:
	; Handle single byte reply

	IFNE	syshook.diag
	btst.b	#5,gpip.w               ; Same first test as the normal driver
	beq.b	.acked                  ;
	moveq	#8,d2                   ; Then wait for IRQ low, and report
	bsr.w	syshook.diagwait        ; while it doesn't come
.acked
	ELSE
.await	btst.b	#5,gpip.w               ; Wait for acknowledge on IRQ
	bne.b	.await                  ;
	ENDC

	move.w	#$008a,(a1)             ; Prepare to read command/status
	move.w	(a0),d0                 ; Read command/status byte

	cmp.b	#$9a,d0                 ; Check if command byte
	beq.b	syshook.fwdres          ; Check command $9a (forward to TOS)
	IFNE	syshook.diag
	blt.w	syshook.execcmd         ; Other commands with parameter
	ELSE
	blt.b	syshook.execcmd         ; Other commands with parameter
	ENDC

.qret	ext.w	d0                      ; Quick return sign-extended d0
	ext.l	d0                      ;

	; Fall through syshook.return
syshook.return:
	; Return from interrupt
	IFNE	syshook.mstefix
	bsr.b	syshook.msteres         ; Set the Mega STE cache back
	ENDC
	sf	flock.w                 ; Unlock floppy controller
	resreg	                        ; Restore registers
	addq	#4,sp                   ; Pop forward address
	rte	                        ; Return

syshook.fwdres:
	IFNE	syshook.mstefix
	bsr.b	syshook.msteres         ; Set the Mega STE cache back
	ENDC
syshook.forward:
	; Command $9a: forward the call to the next handler
	sf	flock.w                 ; Unlock floppy controller
	resreg	                        ; Restore registers
syshook.rts
	rts	                        ; Jump to forwarding address

	IFEQ	syshook.nott

syshook.usrbnc:
	; User mode with parameters above phystop, out of DMA reach: send their
	; address with command $0d instead. The STM32 then fetches exactly the
	; bytes it needs through the supervisor stack.
	lea	syshook.bnbuf(pc),a0    ;
	bra.b	syshook.bncend          ;

syshook.bounce:
	; Supervisor mode: the caller's stack can't be trusted to hold a whole
	; call. It can be tiny: TOS runs the AUTO folder on the 256 bytes of a
	; process descriptor that stays in use afterwards, and what the STM32
	; and interrupts pushed below it overwrote its file handles. It can also
	; be out of DMA reach (program in TT-RAM).
	; Run the call on a private stack and send the caller's sp along with
	; the parameters address, command $0c: the STM32 sets sp back before
	; leaving. The saved registers and the exception frame stay on the
	; caller's stack.
	cmp.w	#$0020,(a2)             ; Don't hook Super, see above
	beq.b	syshook.forward         ;

	lea	syshook.bnbuf(pc),a0    ;
	move.l	sp,4(a0)                ; Store the caller's sp
	IFNE	PRG
	move.l	syshook.stkptr(pc),sp   ; Switch to the private stack
	ELSE
	lea	syshook.stack(pc),sp    ; Switch to the private stack
	ENDC
	subq.b	#1,d0                   ; Command $0e becomes $0c with the next

syshook.bncend:
	move.l	a2,(a0)                 ; Store the parameters address in ST-RAM
	move.l	a0,a2                   ; Point DMA at it
	subq.b	#1,d0                   ; Command $0e becomes $0d
	bra.b	syshook.sendcmd         ;

	ENDC

syshook.init:
	savereg	                        ; Save registers
	IFNE	syshook.diag
	lea	syshook.diagop(pc),a0   ; No GEMDOS call in flight
	move.w	#$ffff,(a0)             ;
	ENDC
	and.w	#$00e0,d0               ; Send "init ok" command
	IFNE	syshook.diag
	bra.w	syshook.sendcmd
	ELSE
	bra.b	syshook.sendcmd
	ENDC

	IFNE	syshook.mstefix

syshook.msteoff:
	; Save the state of the Mega STE cache and turn it off
	; Alters a0 only
	; GEMDRIVE.PRG turns both routines into a rts on other machines
	lea	syshook.mstecst(pc),a0  ;
	move.b	mstecache.w,(a0)        ; Save the cache register
	and.b	#$fe,mstecache.w        ; Clear the cache enable bit
	rts

syshook.msteres:
	; Set the Mega STE cache back to its saved state
	move.b	syshook.mstecst(pc),mstecache.w
	rts

	ENDC

syshook.setprm:
	; Point a2 at the parameters of the initial call
	; The supervisor stack must point at the trap stack frame
	; Alters d2 and a2 only
	; Returns with Z set if the call comes from user mode, clear if from
	; supervisor mode
	btst	#5,8+spoff(sp)          ; Check if supervisor mode
	beq.b	.usp                    ; Branch if user mode

	move.w	prmoff(pc),d2           ; Fetch parameter offset
	lea	8+spoff(sp,d2.w),a2     ; Compute pointer to call parameters
	rts

.usp	move	usp,a2                  ; Point at USP directly
	rts

syshook.rte
	; Command $80: Return long from exception
	move.l	d1,d0                   ; Put parameter in d0
	IFNE	syshook.diag
	bra.w	syshook.return          ; Return from exception
	ELSE
	bra.b	syshook.return          ; Return from exception
	ENDC

syshook.execcmd:
	; Received a command in d0

	; Read parameter (4 bytes) into d1
	; The STM32 flips IRQ when each byte is on the bus: high for the 1st
	; and 3rd, low for the 2nd and 4th. No CPU speed assumption.
	swap	d0                      ; Save command byte into upper d0
	moveq	#3,d2                   ; Repeat 4 times
.rdbyte	move.b	gpip.w,d0               ; Wait until IRQ (bit 5) matches the
	lsr.b	#5,d0                   ; lowest bit of the byte counter
	eor.b	d2,d0                   ;
	lsr.b	#1,d0                   ;
	IFNE	syshook.diag
	bcc.b	.rdnow                  ;
	bsr.w	syshook.diagwait        ; Not yet: wait and report
.rdnow
	ELSE
	bcs.b	.rdbyte                 ;
	ENDC
	move.w	(a0),d0                 ; Read the byte
	lsl.l	#8,d1                   ;
	move.b	d0,d1                   ;
	dbra	d2,.rdbyte              ;
	swap	d0                      ; Restore command byte
	move.l	d1,a0                   ; a0 = parameter, for memory commands

	; Route the call using a jump table
	move.b	d0,d2                   ; Jump table for command byte
	and.w	#$007e,d2               ; Filter out comand pair
	move.w	.jmptbl(pc,d2.w),d2     ;
.jmp	jmp	.jmptbl(pc,d2.w)        ;
.jmptbl	dc.w	syshook.rte-.jmptbl     ; $80
	dc.w	syshook.bytecp-.jmptbl  ; $82
	dc.w	syshook.dmaset-.jmptbl  ; $84
	dc.w	syshook.pexec6-.jmptbl  ; $86
	dc.w	syshook.pexec4-.jmptbl  ; $88
	dc.w	syshook.rdlong-.jmptbl  ; $8a
	dc.w	syshook.rdword-.jmptbl  ; $8c
	dc.w	syshook.rdbyte-.jmptbl  ; $8e
	dc.w	syshook.addsp-.jmptbl   ; $90
	dc.w	syshook.pshword-.jmptbl ; $92
	dc.w	syshook.pushsp-.jmptbl  ; $94
	dc.w	syshook.trap01-.jmptbl  ; $96
	IFEQ	syshook.nott
	dc.w	syshook.flush-.jmptbl   ; $98
	ENDC

syshook.pexec4:
	; Command $88: Pexec4 and rte
	moveq	#4,d0
	bra.b	syshook.pexec

syshook.pexec6:
	; Command $86: Pexec6 and rte
	moveq	#6,d0

	; Fall through syshook.pexec

syshook.pexec:
	IFNE	syshook.mstefix
	bsr.w	syshook.msteres         ; Set the Mega STE cache back
	ENDC
	sf	flock.w                 ; Unlock floppy controller

	; Patch the current Pexec call, then forward
	bsr.w	syshook.setprm          ; Point at Pexec parameters

	addq	#2,a2                   ; Skip Pexec opcode
	move.w	d0,(a2)+                ; Pexec.mode (set to 4 or 6)
	clr.l	(a2)+                   ; Pexec.z1
	move.l	d1,(a2)+                ; Pexec.basepage
	clr.l	(a2)+                   ; Pexec.z2

	resreg	                        ; Restore registers
	rts	                        ; Forward to GEMDOS

	IFEQ	syshook.nott
syshook.flush:
	; Command $98: clear 68020/68030 caches after DMA wrote to RAM
	; Only sent by the STM32 to machines that have these caches
	dc.w	$4e7a,$2002             ; movec	cacr,d2
	or.w	#$0808,d2               ; Clear data and instruction caches
	dc.w	$4e7b,$2002             ; movec	d2,cacr
	bra.b	syshook.dmanset         ; Continue in DMA write mode
	ENDC

syshook.rdlong:
	move.l	(a0),-(sp)
	bra.b	syshook.dmasp

syshook.rdword:
	move.w	(a0),-(sp)
	bra.b	syshook.dmasp

syshook.rdbyte:
	move.b	(a0),-(sp)
	bra.b	syshook.dmasp

syshook.addsp:
	adda.l	d1,sp
	bra.b	syshook.dmasp

syshook.pshword:
	move.w	d1,-(sp)
	bra.b	syshook.dmanset

syshook.pushsp:
	move.l	sp,-(sp)
	bra.b	syshook.dmasp

syshook.trap01:
	trap	#01
	move.l	d0,-(sp)
	moveq	#0,d0                   ; Even like $96: DMA write in dmanset
syshook.dmasp:
	move.l	sp,d1

	; DMA setup
syshook.dmaset:
	move.l	d1,a2                   ; Set parameter as DMA address
syshook.dmanset:
	btst	#0,d0                   ; Check if DMA is read or write
	beq.b	syshook.wcmd            ; DMA write

syshook.rcmd:
	; Continue the command stream in DMA read mode
	; This sends a command byte $00 to signal the STM32 that we are ready.
	bsr.b	syshook.setdmaaddr      ; Set DMA address to a2

	move.w	#$0090,(a1)             ; Set block count
	move.w	#$00ff,(a0)             ; Send 255 blocks
	move.w	#$008a,(a1)             ; Switch to command
	clr.w	(a0)                    ; Send zero command byte
	clr.w	(a1)                    ; Enable DMA

	bra.w	syshook.reply

syshook.bytecp:
	; Commands $82/$83: Byte copy operations
	move.l	sp,a1                   ; Use a1 to leave sp untouched
	move.w	(a1)+,d2                ; Pop byte count and point a1 at data
	move.l	a1,a2                   ; Set DMA on stack data

	btst	#0,d0                   ; Check if read or write
	beq.b	syshook.byteread        ;

	; Command $83: Copy from stack to memory

.cpy    move.b	(a1)+,(a0)+             ; Byte copy from stack to memory
	dbra	d2,.cpy                 ;

	bra.b	syshook.rcmd

syshook.byteread:
	; Command $82: Copy from memory to stack

.cpy    move.b	(a0)+,(a1)+             ; Byte copy from memory to stack
	dbra	d2,.cpy                 ;

	; Fall through syshook.wcmd

syshook.wcmd:
	; Continue the command stream in DMA write mode
	; This sends a command byte $88 to signal the STM32 that we are ready.
	bsr.b	syshook.setdmaaddr      ; Set DMA address to a2

	move.w	#$00ff,(a0)             ; Send 255 blocks
	move.w	#$018a,(a1)             ; Switch to command
	move.w	#$0088,(a0)             ; Send $88 command byte
	move.w	#$0100,(a1)             ; Enable DMA

	bra.w	syshook.reply

syshook.setdmaaddr:
	; Set DMA address and size
	; Input:
	;  a2: DMA address to set

	movem.w	syshook.dmareg(pc),a0-a1; Set DMA controller registers

	move.w	#$0090,(a1)             ; Reset DMA pipeline
	move.w	#$0190,(a1)             ;

	move.l	a2,d1                   ; Set DMA address
	move.b	d1,dmalow.w             ;
	lsr.l	#8,d1                   ;
	move.b	d1,dmamid.w             ;
	lsr.l	#8,d1                   ;
	move.b	d1,dmahigh.w            ;

	rts

	IFNE	syshook.diag

syshook.diagwait:
	; Diagnostic build: wait until IRQ (gpip bit 5) equals bit 0 of d2, like
	; the code that calls it, and report on the console every 10 seconds.
	; d2 is 8 when waiting for a reply, 3 to 0 for a parameter byte.
	movem.l	d0-d1,-(sp)             ;
.again	move.l	#10*200,d1              ; 10 seconds
	add.l	hz200.w,d1              ;
.poll	move.b	gpip.w,d0               ;
	lsr.b	#5,d0                   ;
	eor.b	d2,d0                   ;
	lsr.b	#1,d0                   ;
	bcc.b	.done                   ;
	cmp.l	hz200.w,d1              ;
	bpl.b	.poll                   ;
	bsr.b	syshook.diagrep         ;
	bra.b	.again                  ;
.done	movem.l	(sp)+,d0-d1             ;
	rts

syshook.diagrep:
	; Print the GEMDOS opcode in flight, the last hook command and the wait.
	; Called by syshook.diagwait, whose saved d0 is above the return address.
	; The BIOS alters d0-d2/a0-a2 only.
	movem.l	d0-d4/a0-a3,-(sp)       ;
	lea	syshook.diagmsg(pc),a3  ;
	bsr.b	.puts                   ; "GemDrive waiting: op="
	move.w	syshook.diagop(pc),d3   ;
	moveq	#3,d4                   ;
	bsr.b	.hex                    ;
	bsr.b	.puts                   ; " cmd="
	move.l	40(sp),d3               ; d0 of the waiting code
	cmp.b	#8,11(sp)               ; d2: waiting for a reply ?
	beq.b	.inlow                  ;
	swap	d3                      ; Else the command is in the upper word
.inlow	lsl.w	#8,d3                   ;
	moveq	#1,d4                   ;
	bsr.b	.hex                    ;
	bsr.b	.puts                   ; " wait="
	move.l	8(sp),d3                ; d2
	ror.w	#4,d3                   ;
	moveq	#0,d4                   ;
	bsr.b	.hex                    ;
	bsr.b	.puts                   ; End of line
	movem.l	(sp)+,d0-d4/a0-a3       ;
	rts

.hex	rol.w	#4,d3                   ; Print d4+1 hex digits from the top
	moveq	#$0f,d0                 ; of d3.w
	and.w	d3,d0                   ;
	move.b	.digits(pc,d0.w),d0     ;
	bsr.b	.putc                   ;
	dbra	d4,.hex                 ;
	rts

.puts	move.b	(a3)+,d0                ; Print the string in a3 up to its
	beq.b	.rts                    ; zero, leave a3 after it
	bsr.b	.putc                   ;
	bra.b	.puts                   ;

.putc	and.w	#$00ff,d0               ; Bconout to the console
	move.w	d0,-(sp)                ;
	move.w	#2,-(sp)                ;
	move.w	#3,-(sp)                ;
	trap	#13                     ;
	addq.l	#6,sp                   ;
.rts	rts

.digits	dc.b	'0123456789ABCDEF'
syshook.diagmsg	dc.b	13,10,'GemDrive waiting: op=',0
	dc.b	' cmd=',0
	dc.b	' wait=',0
	dc.b	13,10,0
	even

	ENDC

; Variables
syshook.dmareg	dc.w	dmadata,dmactrl ; DMA port addresses
	IFNE	syshook.diag
syshook.diagop	dc.w	0               ; GEMDOS opcode of the call in flight
	ENDC
	IFNE	syshook.mstefix
syshook.mstecst	dc.w	0               ; Mega STE cache state (high byte)
	ENDC
	

; vim: ff=dos ts=8 sw=8 sts=8 noet colorcolumn=8,41,81 ft=asm68k tw=80
