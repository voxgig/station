// JSON key-declaration order, which Go's map type discards.
//
// THIS FILE EXISTS BECAUSE GO HAS NO ORDERED MAP, and §8.4 makes
// declaration order load-bearing: it is the LAST tie-break of the
// feature order - after constraints, after bands - so two same-band
// features neither of which constrains the other come out in the order
// the config declared them. The canonical library gets that free from a
// JavaScript object; a Go map would turn it into an alphabetical
// accident, which is exactly what §8.4 says the tie-break must not be.
//
// So station.json is parsed ONCE, into the same plain
// map[string]any/[]any/float64 tree encoding/json produces PLUS an Order
// tree mirroring its shape. Everything downstream keeps taking plain
// maps; only the paths that need order ask for it.
//
// A CONFIG PASSED IN CODE (Options.Config) HAS NO ORDER TO READ - a Go
// map literal simply has none - so those instances fall back to sorted
// key order. Documented in README.md as this port's one behavioural
// divergence on §8.4's last tie-break.
package station

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
)

// Order carries the key order of one JSON node, and of every node below
// it. Every method is nil-safe, so a caller can walk a path that does
// not exist without checking at each step.
type Order struct {
	keys  []string
	kids  map[string]*Order
	items []*Order
}

// Keys returns the map keys in declaration order, or nil.
func (order *Order) Keys() []string {
	if nil == order {
		return nil
	}
	return order.keys
}

// Child returns the order of a map's value, or nil.
func (order *Order) Child(key string) *Order {
	if nil == order || nil == order.kids {
		return nil
	}
	return order.kids[key]
}

// Item returns the order of a list's element, or nil.
func (order *Order) Item(index int) *Order {
	if nil == order || 0 > index || index >= len(order.items) {
		return nil
	}
	return order.items[index]
}

// At walks a path of map keys, returning nil at the first missing step.
func (order *Order) At(path ...string) *Order {
	at := order
	for _, key := range path {
		at = at.Child(key)
	}
	return at
}

// ParseOrdered parses JSON into exactly the tree encoding/json produces
// for `any` - map[string]any, []any, float64, string, bool, nil - plus
// the key order of every map in it.
func ParseOrdered(text []byte) (any, *Order, error) {
	dec := json.NewDecoder(bytes.NewReader(text))
	value, order, err := parseordered(dec)
	if nil != err {
		return nil, nil, err
	}
	// Trailing content is malformed JSON, and encoding/json's own
	// Unmarshal rejects it - so this must too, or a truncated file
	// would load as its first value.
	if _, err := dec.Token(); io.EOF != err {
		return nil, nil, errmalformed
	}
	return value, order, nil
}

func parseordered(dec *json.Decoder) (any, *Order, error) {
	token, err := dec.Token()
	if nil != err {
		return nil, nil, err
	}

	delim, isdelim := token.(json.Delim)
	if !isdelim {
		return token, nil, nil
	}

	switch delim {
	case '{':
		node := map[string]any{}
		order := &Order{keys: []string{}, kids: map[string]*Order{}}
		for dec.More() {
			keytoken, err := dec.Token()
			if nil != err {
				return nil, nil, err
			}
			key, is := keytoken.(string)
			if !is {
				return nil, nil, errmalformed
			}
			value, kidorder, err := parseordered(dec)
			if nil != err {
				return nil, nil, err
			}
			if _, has := node[key]; !has {
				order.keys = append(order.keys, key)
			}
			node[key] = value
			order.kids[key] = kidorder
		}
		if _, err := dec.Token(); nil != err {
			return nil, nil, err
		}
		return node, order, nil

	case '[':
		node := []any{}
		order := &Order{items: []*Order{}}
		for dec.More() {
			value, itemorder, err := parseordered(dec)
			if nil != err {
				return nil, nil, err
			}
			node = append(node, value)
			order.items = append(order.items, itemorder)
		}
		if _, err := dec.Token(); nil != err {
			return nil, nil, err
		}
		return node, order, nil
	}

	return nil, nil, errmalformed
}

var errmalformed = errors.New("unexpected JSON structure")
