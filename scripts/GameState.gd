extends Node

## 씬 사이를 건너는 최소 상태. 곡 선택 화면이 고르고 Main 이 읽는다.
##
## Godot 의 change_scene 은 새 씬의 _ready 전에 프로퍼티를 넣을 방법이 없어서
## 이런 전달은 autoload 가 표준 패턴이다. 여기엔 '선택'만 둔다 —
## 점수·체력 같은 플레이 상태는 Main/Score 소유이고 여기 두면 안 된다.

var selected_chart := ""
