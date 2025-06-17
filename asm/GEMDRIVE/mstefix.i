
 MACRO DISABLECACHE
;	tst.b 	ismste
;	beq.b 	.nocache\@
	lea     cachestate(pc),a0
	move.b	$ffff8e21.w,(a0) ;cachestate
	and.b 	#$fe,$ffff8e21.w ;clear cache lines
.nocache\@:	
 ENDM
 MACRO RESTORECACHE
;	tst.b 	ismste
;	beq.b 	.nocache\@
	move.b	cachestate(pc),$ffff8e21.w ;restore cache lines
.nocache\@:	
 ENDM

 MACRO CHECKMSTE
;check for mste (workaround)
 IFEQ 1
	moveq  #0,D0 
	move.l $8.w,d7
	move.l #.nomste,$8.w
	move.b $ffff8e21.w,d6
	moveq  #1,D0 
.nomste:
	move.b d0,ismste
    move.l d7,$8.w
 ENDC
 ENDM