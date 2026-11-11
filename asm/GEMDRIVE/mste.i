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

; Mega STE build of the GemDrive driver
;
; On a Mega STE at 16MHz with its cache enabled, GemDrive hangs. The
; workaround, by tin-nl, is to turn the cache off while the driver talks to
; the STM32 and to set it back afterwards.
;
; MSTE selects the build: 0 for the generic driver (ST, STE, TT), 1 for the
; Mega STE one. It is set on the assembler command line (-DMSTE=1), see
; build_asm.sh and "make mste".
;
; With MSTE set, the driver writes the cache register without checking the
; machine: it only runs on a Mega STE and bombs on anything else. To fit in
; the boot sector, it leaves out what only a 68030 or TT-RAM need: the cache
; flush command and the handling of GEMDOS calls from above phystop, which
; go to TOS instead.

	IFND	MSTE
MSTE	equ	0                       ; Generic driver by default
	ENDC

	; DIAG builds a diagnostic GEMDRIVE.PRG ("make diag"): it replaces the
	; boot sector driver on any machine, and when the STM32 doesn't answer
	; it prints on the console what it is waiting for.
	IFND	DIAG
DIAG	equ	0                       ; Normal driver by default
	ENDC

mstecache	equ	$ffff8e21       ; Cache and CPU speed register
mstemch	equ	$00010010               ; _MCH cookie of the Mega STE

; vim: ff=dos ts=8 sw=8 sts=8 noet colorcolumn=8,41,81 ft=asm68k tw=80
