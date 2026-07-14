import { Pipe, PipeTransform } from '@angular/core';

const DAY_NAMES = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
const MONTH_NAMES = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

function pad(value: number): string {
  return value.toString().padStart(2, '0');
}

/**
 * Formats an ISO-8601 UTC timestamp per the wireframe:
 * `Sunday, 17-May-20 11:18:45 UTC` (tech-design.md §6.2).
 */
@Pipe({ name: 'utcTimestamp', standalone: true })
export class UtcTimestampPipe implements PipeTransform {
  transform(value: string | null | undefined): string {
    if (!value) {
      return '';
    }
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) {
      return '';
    }

    const dayName = DAY_NAMES[date.getUTCDay()];
    const day = pad(date.getUTCDate());
    const month = MONTH_NAMES[date.getUTCMonth()];
    const year = pad(date.getUTCFullYear() % 100);
    const hours = pad(date.getUTCHours());
    const minutes = pad(date.getUTCMinutes());
    const seconds = pad(date.getUTCSeconds());

    return `${dayName}, ${day}-${month}-${year} ${hours}:${minutes}:${seconds} UTC`;
  }
}
