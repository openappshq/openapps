const words =
  "the be of and a to in he have it that for they with as not on she at by this we you do but from or which one would all will there say who make when can more if no man out other so what time up go about than into could state only new year some take come these know see use get like then first any work now may such give over think most even find day also after way many must look before great back through long where much should well people down own just because good each those feel seem how high too place little world very still hand old life tell write sound both between need house under never last same another while might next help home small room part every start turn move change play here again off point right real open clear keep begin end light call learn word read try".split(
    " ",
  );
export function typingWords(count = 300) {
  return Array.from({ length: count }, () => words[Math.floor(Math.random() * words.length)]!).join(
    " ",
  );
}
export function typingScore(text: string, target: string, seconds: number) {
  const expected = target.split(" ");
  let correct = 0;
  const typed = text.split(" ");
  typed.forEach((word, index) => {
    for (let i = 0; i < word.length; i++) if (word[i] === expected[index]?.[i]) correct++;
    if (index < typed.length - 1) correct++;
  });
  return {
    wpm: seconds > 0 ? Math.round(correct / 5 / (seconds / 60)) : 0,
    accuracy: text.length ? Math.round((correct / text.length) * 100) : 100,
  };
}
