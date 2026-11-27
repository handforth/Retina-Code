/// @function Inventory(_capacity)
/// @description Second GML sample: an inventory system, ends inside an unterminated block comment.
/// @param {Real} _capacity Maximum number of slots
#macro INV_DEFAULT_CAPACITY 24
#macro INV_EMPTY -1
#macro INV_SAVE_FILE "inventory_" + string(global.save_slot) + ".json"

#region Item database
global.items = {
    sword:  { name: "Iron Sword",    damage: 12, weight: 3.5, stack: 1,  rarity: "common" },
    potion: { name: "Health Potion", heal: 25,   weight: 0.2, stack: 20, rarity: "common" },
    gem:    { name: "Ruby \"Heart\"", value: 500, weight: .1, stack: 99, rarity: 'rare' },
    key:    { name: @"Old Key", desc: @"A rusty key.
It probably opens something.", stack: 1 },
};
#endregion

function InventorySlot(_id = INV_EMPTY, _count = 0) constructor {
    item_id = _id;
    count = _count;

    static is_empty = function() {
        return item_id == INV_EMPTY || count <= 0;
    };

    static describe = function() {
        if (is_empty()) return "<empty>";
        var _def = global.items[$ item_id];
        return $"{_def.name} x{count}";
    };
}

function Inventory(_capacity = INV_DEFAULT_CAPACITY) constructor {
    capacity = _capacity;
    slots = array_create(capacity, undefined);
    for (var i = 0; i < capacity; i++) slots[i] = new InventorySlot();
    on_change = undefined;

    static add = function(_id, _amount = 1) {
        var _def = global.items[$ _id];
        if (is_undefined(_def)) {
            show_debug_message($"Unknown item '{_id}'");
            return _amount;
        }
        // First pass: stack onto existing slots
        for (var i = 0; i < capacity && _amount > 0; i++) {
            var _s = slots[i];
            if (_s.item_id == _id && _s.count < _def.stack) {
                var _space = _def.stack - _s.count;
                var _moved = min(_space, _amount);
                _s.count += _moved;
                _amount -= _moved;
            }
        }
        // Second pass: fill empty slots
        for (var i = 0; i < capacity && _amount > 0; i++) {
            var _s = slots[i];
            if (_s.is_empty()) {
                _s.item_id = _id;
                _s.count = min(_def.stack, _amount);
                _amount -= _s.count;
            }
        }
        if (is_method(on_change)) on_change(_id);
        return _amount; // leftover
    };

    static remove = function(_id, _amount = 1) {
        var i = capacity - 1;
        while (i >= 0 && _amount > 0) {
            var _s = slots[i];
            if (_s.item_id == _id) {
                var _take = min(_s.count, _amount);
                _s.count -= _take;
                _amount -= _take;
                if (_s.count <= 0) { _s.item_id = INV_EMPTY; _s.count = 0; }
            }
            i--;
        }
        return _amount == 0;
    };

    static total_weight = function() {
        var _w = 0;
        array_foreach(slots, method({ w: 0 }, function(_s, _i) {
            if (!_s.is_empty()) {
                other._w += global.items[$ _s.item_id].weight * _s.count;
            }
        }));
        return _w;
    };

    static save = function() {
        var _data = [];
        for (var i = 0; i < capacity; i++) {
            var _s = slots[i];
            array_push(_data, { id: _s.item_id, n: _s.count });
        }
        var _json = json_stringify({ version: 2, slots: _data }, true);
        var _buf = buffer_create(string_byte_length(_json) + 1, buffer_fixed, 1);
        buffer_write(_buf, buffer_string, _json);
        buffer_save(_buf, INV_SAVE_FILE);
        buffer_delete(_buf);
    };

    static toString = function() {
        var _out = "Inventory[\n";
        for (var i = 0; i < capacity; i++) {
            if (!slots[i].is_empty()) _out += $"  #{i}: {slots[i].describe()}\n";
        }
        return _out + "]";
    };
}

#region Usage
var _inv = new Inventory(8);
_inv.on_change = function(_id) { show_debug_message("changed: " + string(_id)); };
var _left = _inv.add("potion", 45);
_inv.add("sword");
_inv.add("gem", 3);
_inv.remove("potion", 5);
show_debug_message(_inv);
show_debug_message($"weight={_inv.total_weight()} left={_left}");

repeat (3) {
    _inv.add(choose("potion", "gem", "key"));
}

with (obj_chest) {
    if (point_distance(x, y, other.x, other.y) < 32 && !opened) {
        opened = true;
        other.inventory.add(loot, loot_count);
    }
}
#endregion

#region Edge cases
var _hexes = [$00, $FF, $ABCDEF, 0x00, 0XFF];
var _colors = [#000000, #FFFFFF, c_red, make_colour_rgb(255, 128, 0)];
var _accessors = [_inv.slots[0].count, global.items[$ "sword"].damage];
var _str_with_hash = "#region is not a directive inside a string";
var _str_with_macro = "#macro NOT_A_MACRO 1";
var _comment_in_str = "// not /* a */ comment";
var _template_braces = $"{ {a: 1}.a } and {"}"}";
var _verbatim_end = @"ends with backslash \";
var _after_verbatim = "still fine";
#endregion

/* This block comment never closes.
#region Not a region
function NotCode() constructor {}
var _x = "string in comment";
#endregion
