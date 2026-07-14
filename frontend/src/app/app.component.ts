import { Component } from '@angular/core';

/**
 * Application shell.
 *
 * Lays out the "MY SMS MESSENGER" header and the two side-by-side panels
 * described in the wireframe. The panels themselves are implemented by
 * `NewMessageComponent` (CP9) and `MessageHistoryComponent` (CP10); this
 * component just provides the page frame per tech-design.md §8.2/§8.4.
 */
@Component({
  selector: 'app-root',
  standalone: true,
  imports: [],
  templateUrl: './app.component.html',
  styleUrl: './app.component.css',
})
export class AppComponent {
  protected readonly title = 'MY SMS MESSENGER';
}
