// Minimal git smart-HTTP server for the round-trip suite: wraps `git
// http-backend` as CGI so josh-proxy has a real, local, pushable upstream —
// no network, no auth, works on every runner OS. Stdlib only; run with
// `go run test/githttp/main.go -root <dir> -port <p>`.
package main

import (
	"flag"
	"log"
	"net/http"
	"net/http/cgi"
	"os/exec"
)

func main() {
	root := flag.String("root", ".", "directory containing bare repos (GIT_PROJECT_ROOT)")
	port := flag.String("port", "42180", "port to listen on (127.0.0.1 only)")
	flag.Parse()

	gitBin, err := exec.LookPath("git")
	if err != nil {
		log.Fatal("git not found on PATH")
	}
	h := &cgi.Handler{
		Path: gitBin,
		Args: []string{"http-backend"},
		Env: []string{
			"GIT_PROJECT_ROOT=" + *root,
			"GIT_HTTP_EXPORT_ALL=1",
		},
	}
	log.Printf("serving %s on 127.0.0.1:%s", *root, *port)
	log.Fatal(http.ListenAndServe("127.0.0.1:"+*port, h))
}
