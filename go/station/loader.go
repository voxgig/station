package station

import "strings"

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
