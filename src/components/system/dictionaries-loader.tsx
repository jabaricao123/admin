"use client";

// 字典读取层挂载点（system/010）：首屏 effect 拉取 get_dict 并写入模块级缓存；
// 加载前/失败时消费方用 dictionaries.ts 编译期默认值渲染，不阻塞、不白屏。

import * as React from "react";

import { loadDictionaries } from "@/lib/dictionaries";

export function DictionariesLoader() {
  React.useEffect(() => {
    void loadDictionaries();
  }, []);

  return null;
}
