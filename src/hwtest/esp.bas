10 REM karabas: Ф2 board test. UART1 -> ESP8266: AT commands at 115200 8N1, the reply printed;
20 REM then the joysticks (GPIO C / D as the Console8), Esc ends
30 PUT &9F, GET(&9F) OR 3 : PUT &A0, GET(&A0) AND &FC : PUT &A1, GET(&A1) OR 3 : REM PC0 / PC1 = UART1
40 PUT &D3, &80 : PUT &D0, 10 : PUT &D1, 0 : PUT &D3, 3 : PUT &D4, 0 : PUT &D2, 7 : PUT &D1, 0
50 C$ = "AT" : PROCat
60 C$ = "AT+GMR" : PROCat
70 PRINT "Joysticks (Esc ends):"
80 REPEAT
90   C% = GET(&9E) : D% = GET(&A2)
100  PRINT TAB(0); "PC="; RIGHT$("0" + STR$~C%, 2); " PD="; RIGHT$("0" + STR$~(D% AND &F0), 2); "  ";
110  T% = TIME : REPEAT UNTIL TIME > T% + 5
120 UNTIL INKEY(0) = 27
130 PRINT : END
140 DEF PROCat
150 PRINT "> "; C$
160 FOR I% = 1 TO LEN(C$) : PROCtx(ASC(MID$(C$, I%, 1))) : NEXT : PROCtx(13) : PROCtx(10)
170 T% = TIME
180 REPEAT
190   IF GET(&D5) AND 1 THEN B% = GET(&D0) : IF B% <> 13 THEN VDU B%
200 UNTIL TIME > T% + 100
210 PRINT
220 ENDPROC
230 DEF PROCtx(B%)
240 REPEAT UNTIL GET(&D5) AND &20
250 PUT &D0, B%
260 ENDPROC
