package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"crypto/ecdsa"
	"crypto/x509"
	"strings"
	"sync"
	"unsafe"

	"quickconnect.local/engine/lan"
)

var lifecycle sync.Mutex
var session *lan.Session
var events struct {
	sync.Mutex
	queue []string
}

func report(event string) {
	events.Lock()
	defer events.Unlock()
	if len(events.queue) == 32 {
		events.queue = events.queue[1:]
	}
	events.queue = append(events.queue, strings.ReplaceAll(event, "\n", " "))
}

//export qcStart
func qcStart(ip, host *C.char, port C.int, keyBytes unsafe.Pointer, length C.int) *C.char {
	lifecycle.Lock()
	defer lifecycle.Unlock()
	if session != nil {
		return C.CString("Eine LAN-Sitzung läuft bereits.")
	}
	if port < 1 || port > 65535 {
		return C.CString("Ungültiger Port.")
	}
	key, err := x509.ParsePKCS8PrivateKey(C.GoBytes(keyBytes, length))
	if err != nil {
		return C.CString("NetherNet-Identität konnte nicht gelesen werden.")
	}
	ec, ok := key.(*ecdsa.PrivateKey)
	if !ok || ec.Params().BitSize != 384 {
		return C.CString("NetherNet benötigt einen P-384-Schlüssel.")
	}
	qcClear()
	session, err = lan.Start(C.GoString(ip), C.GoString(host), uint16(port), ec, false, report)
	if err != nil {
		return C.CString(lan.Message(err))
	}
	return nil
}

//export qcStop
func qcStop() {
	lifecycle.Lock()
	defer lifecycle.Unlock()
	if session != nil {
		session.Close()
		session = nil
	}
	qcClear()
}

func qcClear() {
	events.Lock()
	defer events.Unlock()
	events.queue = nil
}

//export qcEvents
func qcEvents() *C.char {
	events.Lock()
	defer events.Unlock()
	if len(events.queue) == 0 {
		return nil
	}
	result := C.CString(strings.Join(events.queue, "\n"))
	events.queue = nil
	return result
}

func main() {}
