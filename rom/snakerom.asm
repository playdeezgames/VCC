* snakerom.asm - the open ROM with Snake built in: it boots straight into the
* game. BREAK leaves the game for the monitor prompt.
*
*   ./asm6809 rom/snakerom.asm -o rom/snake.rom
*   ./vcc --rom rom/snake.rom

AUTOSTART	equ 1
	include "boot.asm"
