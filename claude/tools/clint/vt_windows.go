package main

import (
	"os"
	"syscall"
	"unsafe"
)

// enableVT turns on escape code handling in the Windows console, so colors render instead of printing as junk. It
// reports false when stdout is not a console.
func enableVT() bool {
	k := syscall.NewLazyDLL("kernel32.dll")
	get, set := k.NewProc("GetConsoleMode"), k.NewProc("SetConsoleMode")
	h := os.Stdout.Fd()
	var mode uint32
	if ok, _, _ := get.Call(h, uintptr(unsafe.Pointer(&mode))); ok == 0 {
		return false
	}
	const vt = 0x0004 // ENABLE_VIRTUAL_TERMINAL_PROCESSING
	ok, _, _ := set.Call(h, uintptr(mode|vt))
	return ok != 0
}
