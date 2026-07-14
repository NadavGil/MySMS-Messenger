import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { ComponentFixture, TestBed } from '@angular/core/testing';
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
    expect(component.form.invalid).toBeTrue();
    const submitButton: HTMLButtonElement = fixture.nativeElement.querySelector('.submit-button');
    expect(submitButton.disabled).toBeTrue();
  });

  it('is invalid when the phone number is not E.164', () => {
    component.form.controls.toNumber.setValue('0123');
    component.form.controls.body.setValue('hello');
    expect(component.form.invalid).toBeTrue();
  });

  it('becomes valid with a proper E.164 number and a non-empty body', () => {
    component.form.controls.toNumber.setValue('+14155550123');
    component.form.controls.body.setValue('hello');
    expect(component.form.valid).toBeTrue();

    fixture.detectChanges();
    const submitButton: HTMLButtonElement = fixture.nativeElement.querySelector('.submit-button');
    expect(submitButton.disabled).toBeFalse();
  });

  it('rejects a body over 250 characters', () => {
    component.form.controls.toNumber.setValue('+14155550123');
    component.form.controls.body.setValue('a'.repeat(251));
    expect(component.form.invalid).toBeTrue();
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
    spyOn(store, 'refresh');

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
    expect(component.submitting).toBeFalse();
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
    expect(component.submitting).toBeFalse();
  });

  it('does not submit while the form is invalid', () => {
    component.onSubmit();
    httpMock.expectNone(baseUrl);
  });
});
