// dataverify 项在客体（Android，linux/amd64）里跑的小程序：按写入计划把花样文件的一段段字节写进数据文件，
// 计划里标了直写的块用 O_DIRECT 写，其余用普通写。客体自带的 toybox dd 没有 oflag=direct，所以需要它。
// 不读不写别的东西：花样、计划都由宿主（items\dataverify-lib.ps1）算好推进来，写完的哈希由客体的 sha256sum 算。
// 宿主上的 items\dataverify.ps1 用 `go build`（GOOS=linux GOARCH=amd64 CGO_ENABLED=0）编它，不要在 Windows 宿主上运行。
//
//	dvwrite <花样文件> <数据文件> <计划文件>
//
// 计划文件每行 `<偏移> <大小> <0|1>`（1 = 直写）；文件偏移 o 处写的是花样[o mod 花样长度] 起的 <大小> 字节。
package main

import (
	"bufio"
	"fmt"
	"os"
	"syscall"
)

func fail(format string, a ...any) {
	fmt.Printf("DV-WRITE-FAIL "+format+"\n", a...)
	os.Exit(1)
}

func main() {
	if len(os.Args) != 4 {
		fmt.Fprintln(os.Stderr, "usage: dvwrite <pattern> <file> <plan>")
		os.Exit(2)
	}
	pattern, err := os.ReadFile(os.Args[1])
	if err != nil || len(pattern) == 0 {
		fail("read pattern: %v", err)
	}
	bf, err := os.OpenFile(os.Args[2], os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
	if err != nil {
		fail("open buffered: %v", err)
	}
	df, err := os.OpenFile(os.Args[2], os.O_WRONLY|syscall.O_DIRECT, 0)
	if err != nil {
		fail("open O_DIRECT: %v", err)
	}
	// O_DIRECT 要内存对齐：匿名映射是页对齐的
	buf, err := syscall.Mmap(-1, 0, 1<<20, syscall.PROT_READ|syscall.PROT_WRITE, syscall.MAP_ANON|syscall.MAP_PRIVATE)
	if err != nil {
		fail("mmap: %v", err)
	}
	pf, err := os.Open(os.Args[3])
	if err != nil {
		fail("open plan: %v", err)
	}
	sc := bufio.NewScanner(pf)
	chunks, direct := 0, 0
	for sc.Scan() {
		var off int64
		var size, d int
		if _, err := fmt.Sscanf(sc.Text(), "%d %d %d", &off, &size, &d); err != nil {
			fail("plan line %q: %v", sc.Text(), err)
		}
		start := int(off % int64(len(pattern)))
		if size <= 0 || size > len(buf) || start+size > len(pattern) {
			fail("chunk %d@%d out of range", size, off)
		}
		src := pattern[start : start+size]
		f := bf
		if d == 1 {
			copy(buf, src)
			src, f = buf[:size], df
			direct++
		}
		if n, err := f.WriteAt(src, off); err != nil || n != size {
			fail("write %d@%d direct=%d: n=%d err=%v", size, off, d, n, err)
		}
		chunks++
	}
	for _, f := range []*os.File{bf, df} {
		if err := f.Sync(); err != nil {
			fail("fsync: %v", err)
		}
		f.Close()
	}
	fmt.Printf("DV-WRITE-OK chunks=%d direct=%d\n", chunks, direct)
}
