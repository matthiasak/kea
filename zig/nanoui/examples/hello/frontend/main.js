// The client is generated from the Zig services (see nanoui.d.ts for types).
import { Greeter, Todos, onTick } from "/nanoui.js";

const $ = (id) => document.getElementById(id);

$("greet-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  $("greeting").textContent = await Greeter.greet($("name").value);
});

const render = (todos) => {
  $("count").textContent = `${todos.filter((t) => !t.done).length} left`;
  $("todos").replaceChildren(
    ...todos.map((t) => {
      const li = document.createElement("li");
      li.className = t.done ? "done" : "";
      const box = document.createElement("input");
      box.type = "checkbox";
      box.checked = t.done;
      box.onchange = async () => {
        await Todos.toggle(t.id);
        refresh();
      };
      const title = document.createElement("span");
      title.textContent = t.title;
      const del = document.createElement("button");
      del.className = "ghost";
      del.textContent = "×";
      del.onclick = async () => {
        await Todos.remove(t.id);
        refresh();
      };
      li.append(box, title, del);
      return li;
    }),
  );
};

const refresh = async () => render(await Todos.list());

$("todo-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  $("error").textContent = "";
  try {
    await Todos.add($("title").value);
    $("title").value = "";
    refresh();
  } catch (err) {
    $("error").textContent = err.message;
  }
});

onTick(({ uptime }) => {
  $("uptime").textContent = `${uptime}s`;
});

refresh();
