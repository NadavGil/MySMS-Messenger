import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { ComponentFixture, TestBed } from '@angular/core/testing';
import { vi } from 'vitest';
import { environment } from '../../../environments/environment';
import { MessagesStoreService } from '../../services/messages-store.service';
import { NewMessageComponent } from './new-message.component';

describe('NewMessageComponent', () => {
  let fixture: ComponentFixture<NewMessageComponent>;
  let component: NewMessageComponent;
  let httpMock: HttpTestingController;
  const baseUrl = `${environment.apiBaseUrl}/api/v1/messages`;

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [NewMessageComponent, HttpClientTestingModule],
    }).compileComponents();

    fixture = TestBed.createComponent(NewMessageComponent);
    component = fixture.componentInstance;
    httpMock = TestBed.inject(HttpTestingController);
    fixture.detectChanges();
  });

  afterEach(() => {
    httpMock.verify();
  });

  it('creates the component', () => {
    expect(component).toBeTruthy();
  });

  it('starts with an invalid, empty form and Submit disabled', () => {
    expect(component.form.invalid).toBe(true);
    const submitButton: HTMLButtonElement = fixture.nativeElement.querySelector('.submit-button');
    expect(submitButton.disabled).toBe(true);
  });

  it('is invalid when the phone number is not E.164', () => {
    component.form.controls.toNumber.setValue('0123');
    component.form.controls.body.setValue('hello');
    expect(component.form.invalid).toBe(true);
  });

  it('becomes valid with a proper E.164 number and a non-empty body', () => {
    component.form.controls.toNumber.setValue('+14155550123');
    component.form.controls.body.setValue('hello');
    expect(component.form.valid).toBe(true);

    fixture.detectChanges();
    const submitButton: HTMLButtonElement = fixture.nativeElement.querySelector('.submit-button');
    expect(submitButton.disabled).toBe(false);
  });

  it('rejects a body over 250 characters', () => {
    component.form.controls.toNumber.setValue('+14155550123');
    component.form.controls.body.setValue('a'.repeat(251));
    expect(component.form.invalid).toBe(true);
    expect(component.form.controls.body.errors?.['maxlength']).toBeTruthy();
  });

  it('updates the live N/250 counter as the body changes', () => {
    component.form.controls.body.setValue('hello');
    fixture.detectChanges();
    expect(component.bodyLength).toBe(5);
    const counter: HTMLElement = fixture.nativeElement.querySelector('.char-counter');
    expect(counter.textContent?.trim()).toBe('5/250');

    component.form.controls.body.setValue('');
    fixture.detectChanges();
    expect(component.bodyLength).toBe(0);
  });

  it('counts emoji by codepoint, not UTF-16 code unit (QA report round1 N1)', () => {
    // '🎉' is a single Unicode codepoint but a UTF-16 surrogate pair, so raw
    // JS `.length` would report 6 here; codepoint-accurate counting must
    // report 3.
    const body = '🎉🎉🎉';
    expect(body.length).toBe(6);

    component.form.controls.body.setValue(body);
    fixture.detectChanges();

    expect(component.bodyLength).toBe(3);
    const counter: HTMLElement = fixture.nativeElement.querySelector('.char-counter');
    expect(counter.textContent?.trim()).toBe('3/250');
  });

  it('rejects a body over 250 codepoints even when built from surrogate-pair emoji', () => {
    component.form.controls.toNumber.setValue('+14155550123');
    // 251 emoji => 251 codepoints, 502 UTF-16 units — raw `.length` maxlength
    // would have accepted this well past the true 250-codepoint limit.
    component.form.controls.body.setValue('🎉'.repeat(251));
    expect(component.form.invalid).toBe(true);
    expect(component.form.controls.body.errors?.['maxlength']).toBeTruthy();
  });

  it('Clear resets the form and any error message', () => {
    component.form.controls.toNumber.setValue('+14155550123');
    component.form.controls.body.setValue('hello');
    component.errorMessage = 'some error';

    component.onClear();

    expect(component.form.controls.toNumber.value).toBe('');
    expect(component.form.controls.body.value).toBe('');
    expect(component.errorMessage).toBeNull();
  });

  it('sends the message, clears the form, and refreshes the store on success', () => {
    const store = TestBed.inject(MessagesStoreService);
    // Vitest's spyOn calls through to the real implementation by default
    // (unlike Jasmine's, which stubs unless .and.callThrough() is added) -
    // stub it here since this test only asserts refresh() was invoked, not
    // what it does; the real refresh() behavior is covered by
    // messages-store.service.spec.ts and would otherwise leave an
    // un-flushed GET request open against httpMock.
    vi.spyOn(store, 'refresh').mockImplementation(() => {});

    component.form.controls.toNumber.setValue('+14155550123');
    component.form.controls.body.setValue('hello');
    component.onSubmit();

    const req = httpMock.expectOne(baseUrl);
    expect(req.request.method).toBe('POST');
    req.flush({
      id: '1',
      to_number: '+14155550123',
      body: 'hello',
      status: 'sent',
      external_sid: 'FAKE-1',
      created_at: '2020-05-17T11:18:45Z',
    });

    expect(component.form.controls.body.value).toBe('');
    expect(store.refresh).toHaveBeenCalled();
    expect(component.submitting).toBe(false);
  });

  it('shows an inline error message when the send fails', () => {
    component.form.controls.toNumber.setValue('+14155550123');
    component.form.controls.body.setValue('hello');
    component.onSubmit();

    const req = httpMock.expectOne(baseUrl);
    req.flush(
      { errors: { body: ['must be 250 characters or fewer'] } },
      { status: 422, statusText: 'Unprocessable Entity' },
    );

    expect(component.errorMessage).toContain('must be 250 characters or fewer');
    expect(component.submitting).toBe(false);
  });

  it('does not submit while the form is invalid', () => {
    component.onSubmit();
    httpMock.expectNone(baseUrl);
  });
});
