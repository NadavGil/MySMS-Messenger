import { Component } from '@angular/core';
import { NewMessageComponent } from './components/new-message/new-message.component';
import { MessageHistoryComponent } from './components/message-history/message-history.component';

/**
 * Application shell.
 *
 * Lays out the "MY SMS MESSENGER" header and the two side-by-side panels
 * described in the wireframe: `NewMessageComponent` (CP9) and
 * `MessageHistoryComponent` (CP10), per tech-design.md §8.2/§8.4.
 */
@Component({
  selector: 'app-root',
  standalone: true,
  imports: [NewMessageComponent, MessageHistoryComponent],
  templateUrl: './app.component.html',
  styleUrl: './app.component.css',
})
export class AppComponent {
  protected readonly title = 'MY SMS MESSENGER';
}
