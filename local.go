package main

// Desktop on the panel's own server: asked by the installer and menu item 10.

import (
	"fmt"
	"net"
	"strconv"
	"strings"
)

func localServer(st *Store) *Server {
	list, _ := st.Servers()
	for _, s := range list {
		if s.Local {
			return s
		}
	}
	return nil
}

func rdpAddr(st *Store, s *Server) string {
	h := orStr(st.Cfg.PublicHost, "SERVER_IP")
	if strings.Contains(h, ":") {
		h = "[" + h + "]"
	}
	return h + ":" + strconv.Itoa(s.RDPPort)
}

func rdpPortFree(p int) bool {
	l, err := net.Listen("tcp", ":"+strconv.Itoa(p))
	if err != nil {
		return false
	}
	l.Close()
	return true
}

// localInstall asks for the desktop user, password, RDP port and Firefox,
// then installs IceWM + xrdp on this server in the foreground.
func localInstall(st *Store) {
	sv := localServer(st)
	fmt.Println()
	fmt.Println("  " + gold(cBold+"Remote Desktop on this server") + dim("  (IceWM + xrdp)"))
	fmt.Println()
	if sv == nil {
		sv = &Server{ID: randHex(10), Local: true, Host: "localhost", SSHPort: 22, SSHUser: "root", Status: "new",
			Name: localName(), RDPPort: 3389, DeskUser: "desktop", Firefox: true}
	} else {
		fmt.Println(dim("  Already set up; press Enter to keep each value."))
	}
	for {
		u := strings.ToLower(strings.TrimSpace(prompt("Desktop username", sv.DeskUser)))
		if userRe.MatchString(u) && !reserved[u] {
			sv.DeskUser = u
			break
		}
		fmt.Println("  " + cRed + "3-32 lowercase letters, digits, - or _ (not root)." + cReset)
	}
	for {
		q := "Desktop password (min 8)"
		if sv.DeskPass != "" {
			q += dim(" [Enter = keep]")
		}
		p := readSecret(q)
		if p == "" && sv.DeskPass != "" {
			break
		}
		if len(p) < 8 {
			fmt.Println("  " + cRed + "At least 8 characters." + cReset)
			continue
		}
		if readSecret("Repeat password") != p {
			fmt.Println("  " + cRed + "Passwords do not match." + cReset)
			continue
		}
		sv.DeskPass = st.Encrypt(p)
		break
	}
	for {
		p, err := strconv.Atoi(prompt("Remote Desktop port", strconv.Itoa(sv.RDPPort)))
		if err != nil || p < 1 || p > 65535 || p == st.Cfg.Port {
			fmt.Println("  " + cRed + "Invalid port." + cReset)
			continue
		}
		if p != sv.RDPPort || sv.Status != "installed" {
			if !rdpPortFree(p) {
				fmt.Printf("  %sPort %d is in use.%s\n", cRed, p, cReset)
				continue
			}
		}
		sv.RDPPort = p
		break
	}
	sv.Firefox = !strings.HasPrefix(strings.ToLower(prompt("Install Firefox too? (Y/n)", map[bool]string{true: "y", false: "n"}[sv.Firefox])), "n")
	if err := st.SaveServer(sv); err != nil {
		fmt.Println("  Save failed:", err)
		return
	}
	fmt.Println()
	err := NewRunner(st).RunSync(sv.ID, "install", func(l string) { fmt.Println("  " + dim("│") + " " + l) })
	fmt.Println()
	if err != nil {
		fmt.Println("  " + cRed + "Desktop install failed." + cReset + " Retry from the menu (sd) or the panel.")
		return
	}
	fmt.Println("  " + cGreen + "✔ Remote Desktop is ready" + cReset)
	fmt.Println("    Address:   " + bold(rdpAddr(st, sv)))
	fmt.Println("    Username:  " + sv.DeskUser)
	fmt.Println(dim("    Open the port in your provider's firewall if it has one."))
	fmt.Println()
}
