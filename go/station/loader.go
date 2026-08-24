// §6.3's LOADER, and why this file has no loader in it.
//
// Three paths fill the factory table (§6.2): module self-registration,
// Station.Provide, and the loader - `api.<slug>.package`, which station
// imports by name at run time so the config closes the loop on its own.
// The third one needs import-by-name at run time. GO LINKS ITS
// DEPENDENCIES: there is no such thing here, and a `plugin` package
// build is a different artifact with its own toolchain constraints, not
// the ordinary dependency graph a reviewer reads in go.mod. So this port
// has the first two paths and says so - in README.md, in the
// station_no_factory message, and in one warning event per api at Open()
// for a config that carries `package` anyway.
//
// `package` and `export` STAY IN THE GRAMMAR: they are shape keys, the
// corpus validates configs that carry them, and one station.json serves
// a polyglot fleet. Ignoring a key is this port's business; removing it
// from the grammar would be everyone's.
//
// What survives from typescript/src/loader.ts is CheckPackage, which is
// pure: the rule for what may appear in that key at all. It is exported
// so a Go-side tool can hold a shared config to the same rule the ports
// that DO load will apply, and nothing in this port calls it - which is
// why station_sdk_load, though it stays in the §14 catalog, is never
// raised here on its own.
package station

import "strings"

// CheckPackage accepts only MODULE NAMES, resolved by the host
// language's ordinary resolution from the application root: never a
// filesystem path, never a URL, never anything relative.
//
// THE SEGMENT CHECK IS NOT OPTIONAL AND IS NOT IMPLIED BY THE PREFIX
// CHECKS. `pkg/../../escape` starts with neither `.` nor `/`, so a
// first-character check passes it, and a host that resolves it walks out
// of the named dependency and imports application-local code from
// outside it. The whole point of this function is that a configured
// package stays inside the dependency graph a reviewer can see.
func CheckPackage(api string, pkg string) (string, error) {
	bad := "" == pkg ||
		strings.HasPrefix(pkg, ".") ||
		strings.HasPrefix(pkg, "/") ||
		strings.HasPrefix(pkg, "~") ||
		strings.Contains(pkg, "://") ||
		strings.Contains(pkg, "\\")

	if !bad {
		for _, segment := range strings.Split(pkg, "/") {
			if "." == segment || ".." == segment {
				bad = true
				break
			}
		}
	}

	if bad {
		return "", fail("station_sdk_load",
			"api \""+api+"\": `package` must be a module name resolved from "+
				"the application root, not a path or URL: "+
				CanonicalSerialize(pkg))
	}
	return pkg, nil
}
