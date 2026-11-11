; ACSI2STM Atari hard drive emulator
; Copyright (C) 2019-2025 by Jean-Matthieu Coulon

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

; PRG loader for the GemDrive system hook

	incdir	..\inc\
	include	tos.i
	include	mste.i

PRG	equ	1                       ; GEMDRIVE.PRG variant of syshook.s

	opt	O+

; Command-line is used as BSS after going resident.
; Structure, repeated up to 8 times
;	dc.l	'XBRA'                  ; XBRA marker
;	dc.l	XBRA                    ;
;	dc.l	$00000000               ; Old vector address
;	move.l	oldvector(pc),-(sp)     ; Push old vector
;	moveq	#acsiid+$0e,d0          ; d0 = command byte to send
;	bra.b	syshook                 ; Enter syshook command mode

	text

XBRA	equ	'A2ST'                  ; XBRA marker
BOOTCMD	equ	$11                     ; Boot command

start	bra.w	main                    ; Initialization is in the freed zone

	include	syshook.s

prmoff	dc.w	$0006                   ; Detected during initialization
syshook.bnbuf	ds.l	2               ; See syshook.bounce
syshook.stkptr	ds.l	1               ; Top of the private stack

syshook.end
	; Freed zone: everything after this is freed when the driver is made
	; resident, then reused as the private stack (see syshook.bounce).
syshook.stack	equ	syshook.end+syshook.stksize

	include	init.s

	; Strings
alrdyin	dc.b	7,'GemDrive already installed',13,10,0
	IFNE	DIAG
tkover	dc.b	'GemDrive: diagnostic driver installed',13,10,0
	ELSE
tkover	dc.b	'GemDrive: Mega STE driver installed',13,10,0
	ENDC
wrgver	dc.b	7,'GEMDRIVE.PRG and firmware versions differ',13,10,0
devnfnd	dc.b	'No GemDrive device detected',13,10,0
nostram	dc.b	7,'GemDrive must load in ST-RAM',13,10,0
	even

	bss

	ds.b	256                     ; Temporary stack for initialization
stack		                        ;

end

; vim: ff=dos ts=8 sw=8 sts=8 noet colorcolumn=8,41,81 ft=asm68k tw=80
