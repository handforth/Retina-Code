/// @description Player step event — GML lexer stress sample
/// @param {Real} delta  The frame delta
/// @returns {undefined}
// GameMaker Language: #macro, #region, function/constructor, with/repeat, template strings

#macro GRAVITY 0.5
#macro MAX_SPEED 8
#macro DEBUG_MODE true
#macro Config:DEBUG_MODE false
#macro LONG_MACRO show_debug_message("macro with " + \
    "line continuation")
#macro COLOR_ORANGE $0080FF

#region Variables
/* Block comment with "strings" and 'quotes'
   spanning multiple lines */
var _input_h = keyboard_check(vk_right) - keyboard_check(vk_left);
var _jump = keyboard_check_pressed(vk_space) || gamepad_button_check_pressed(0, gp_face1);
var _str1 = "double \"quoted\" with \\ and \n and \t";
var _str2 = 'single quoted is also a string in GML';
var _str3 = @"verbatim string with \n literal and "" quotes";
var _str4 = @'verbatim single with \ backslash';
var _multi = @"verbatim strings
can span
multiple lines";
var _template = $"Player {name} has {hp}/{max_hp} HP and {array_length(items)} items";
var _nested_template = $"Outer {string_upper($"inner {name}")} done";
var _escaped_brace = $"Literal \{brace\} and {x}";
var _unicode = "☺ \x41 \101";
var _trailing = "ends with backslash \\";
var _unterminated = "never closes
var _after = 1;
#endregion

#region Numbers
var _dec = 42;
var _float = 3.14159;
var _leading_dot = .5;
var _hex1 = 0xFF_FF;
var _hex2 = $FF00FF;     // GML hex with dollar sign
var _bin = 0b1010_1010;
var _neg = -0.25;
var _exp = 1e-3;
var _big = 1_000_000;
var _col = #FF8000;      // CSS-style colour literal
#endregion

#region Movement
hsp = _input_h * MAX_SPEED;
vsp += GRAVITY;

if (place_meeting(x, y + 1, obj_wall) && _jump) {
    vsp = -12;
    audio_play_sound(snd_jump, 10, false);
}

// Horizontal collision
if (place_meeting(x + hsp, y, obj_wall)) {
    while (!place_meeting(x + sign(hsp), y, obj_wall)) {
        x += sign(hsp);
    }
    hsp = 0;
}
x += hsp;

// Vertical collision
if (place_meeting(x, y + vsp, obj_wall))
{
    repeat (abs(vsp)) {
        if (!place_meeting(x, y + sign(vsp), obj_wall)) y += sign(vsp); else break;
    }
    vsp = 0;
}
y += vsp;
#endregion

#region Functions and constructors
function Vector2(_x = 0, _y = 0) constructor {
    x = _x;
    y = _y;

    static add = function(_other) {
        return new Vector2(x + _other.x, y + _other.y);
    };

    static length = function() {
        return sqrt(x * x + y * y);
    };

    static toString = function() {
        return $"Vector2({x}, {y})";
    };
}

function Vector3(_x, _y, _z) : Vector2(_x, _y) constructor {
    z = _z;
    static length = function() {
        return sqrt(x * x + y * y + z * z);
    };
}

function clamp_speed(_value, _max = MAX_SPEED) {
    gml_pragma("forceinline");
    return clamp(_value, -_max, _max);
}

var _lambda = function(_a, _b) { return _a + _b; };
var _v = new Vector2(3, 4);
var _len = _v.length();
show_debug_message("Length: " + string(_len));
#endregion

#region Control flow
with (obj_enemy) {
    if (distance_to_object(other) < 64) {
        hp -= other.damage;
        instance_destroy(id, true);
    }
}

with (all) { visible = true; }

for (var i = 0; i < 10; i++) {
    if (i mod 2 == 0) continue;
    if (i div 3 > 2) break;
}

do {
    _input_h--;
} until (_input_h <= 0);

switch (state) {
    case PlayerState.Idle:
        sprite_index = spr_player_idle;
        break;
    case PlayerState.Run:
    case PlayerState.Walk:
        sprite_index = spr_player_run;
        break;
    default:
        state = PlayerState.Idle;
}

try {
    var _data = json_parse(@'{"key": "value", "n": 1}');
} catch (_e) {
    show_debug_message($"Error: {_e.message}");
} finally {
    show_debug_message("done");
}
#endregion

#region Data structures and accessors
enum PlayerState {
    Idle,
    Run = 5,
    Walk,
    Jump = $10,
}

var _arr = [1, 2, [3, 4]];
var _first = _arr[0];
var _nested = _arr[2][1];
var _struct = { name: "Hero", hp: 100, "quoted key": true, inner: { a: 1 } };
var _name = _struct.name;
var _map = ds_map_create();
_map[? "key"] = "value";
var _list = ds_list_create();
_list[| 0] = 10;
var _grid = ds_grid_create(4, 4);
_grid[# 1, 2] = 5;
_arr[@ 0] = 99;
var _s = _struct[$ "hp"];
var _ternary = hp > 50 ? "healthy" : "hurt";
var _nullish = _struct[$ "missing"] ?? "default";
_struct.hp ??= 50;
var _bits = (1 << 4) | (0xF & ~2) ^ 3 >> 1;
var _logic = (a and b) or (not c) xor d;
global.score += 10;
self.x = other.x;
#endregion

/* final comment, properly closed */
