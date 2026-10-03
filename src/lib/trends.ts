const DAY = 24 * 60 * 60 * 1000;

export type WeeklySignupPoint = { week: string; count: number };

/** 将用户注册时间聚合成最近 N 周（周一为起点）的新增数 */
export function buildWeeklySignupTrend(
  rows: { created_at: string }[],
  weeks = 12,
): WeeklySignupPoint[] {
  const thisMonday = startOfMonday(new Date());
  const buckets = Array.from({ length: weeks }, (_, index) => {
    const start = new Date(thisMonday.getTime() - (weeks - 1 - index) * 7 * DAY);
    return {
      time: start.getTime(),
      week: `${start.getMonth() + 1}/${start.getDate()}`,
      count: 0,
    };
  });

  for (const row of rows) {
    const mondayTime = startOfMonday(new Date(row.created_at)).getTime();
    const bucket = buckets.find((item) => item.time === mondayTime);
    if (bucket) {
      bucket.count += 1;
    }
  }

  return buckets.map(({ week, count }) => ({ week, count }));
}

function startOfMonday(date: Date) {
  const result = new Date(date);
  result.setHours(0, 0, 0, 0);
  result.setDate(result.getDate() - ((result.getDay() + 6) % 7));
  return result;
}
